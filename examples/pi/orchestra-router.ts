// orchestra/auto: a Pi virtual model that picks a thinking level for each request on ONE physical model.
//
// The model never changes: switching models makes the next model read the whole context again at full price (prompt
// caches are per model) and drops its thinking blocks. Only the thinking level moves. Obvious work gets little or
// no thinking, hard/risky work gets more, and session spend and context usage pull the level down. An optional
// classifier model can make the tier call before the deterministic scorer does.
//
// Install: link this file into ~/.pi/agent/extensions/ (or start pi with `-e ./orchestra-router.ts`) and select
// `orchestra/auto`. In orchestra-worker, set ORCHESTRA_MODEL=orchestra/auto and ORCHESTRA_ROUTER_EXT=<this file>.
//
// The helpers below are pure and exported so the offline suite (tests/router.sh) can exercise them with `node`,
// without a model or a Pi runtime. Keep this file plain ESM JavaScript: Pi loads it as TypeScript, node imports it
// directly for tests.
// @ts-nocheck

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const DEFAULT_MODEL = "deepseek/deepseek-v4-pro";
const FLASH_MODEL = "deepseek/deepseek-flash";
const DEFAULT_SOFT_BUDGET = 1.5;
const DEFAULT_HARD_BUDGET = 4.0;
const DEFAULT_CTX_PRESSURE = 0.7;

// One profile per model family, each with exactly one physical model. The orchestrator picks a profile
// (orchestra/<family>-auto) and the router only varies the thinking level on that model. Budgets and context
// pressure are shared: they are session economics, not model-family properties.
const PROFILE_DEFAULTS = {
  ds: { model: DEFAULT_MODEL, tiers: { routine: "off", standard: "low", deep: "medium" }, levels: ["off", "low", "medium", "high", "xhigh"] },
  gemini: { model: "antigravity/gemini-4-carbon", tiers: { routine: "off", standard: "low", deep: "medium" }, levels: ["off", "low", "medium", "high"] },
  claude: { model: "antigravity/claude-opus-5-5", tiers: { routine: "off", standard: "low", deep: "medium" }, levels: ["off", "low", "medium", "high"] },
  // Anthropic models reached through Claude Code and the user's Claude subscription (pi-claude-bridge), not through
  // Antigravity. Same thinking ladder as the antigravity claude profile: the bridge forwards the level to Claude Code.
  cb: { model: "claude-bridge/claude-opus-5-5", tiers: { routine: "off", standard: "low", deep: "medium" }, levels: ["off", "low", "medium", "high"] },
  // Profile for orchestra workers: always Flash. Flash has no "medium" thinking tier (its catalog map is
  // off/low/high), so "deep" maps straight to "high".
  flash: { model: FLASH_MODEL, tiers: { routine: "off", standard: "low", deep: "high" }, levels: ["off", "low", "high"] },
};
// Virtual-model id -> profile key. "auto" is the legacy id and stays the DeepSeek profile so an existing
// ORCHESTRA_ROUTER_STRONG pin keeps working; "flash-auto" is the worker profile (always Flash).
const PROFILE_BY_ID = {
  auto: "ds",
  "ds-auto": "ds",
  "gemini-auto": "gemini",
  "claude-auto": "claude",
  "cb-auto": "cb",
  "flash-auto": "flash",
};

const LEVELS = ["off", "low", "medium", "high", "xhigh"];
const TIERS = ["routine", "standard", "deep"];
// Providers that run the model's tool loop themselves (Claude Code behind pi-claude-bridge, agy behind the Antigravity
// bridge): pi's first request of a user turn starts one closed loop, and the tool steps after it never reach the
// provider as new requests with their own thinking level. On those, only the user-turn level takes effect.
const DEFAULT_CLOSED_LOOP = "claude-bridge,antigravity";
const FAILURE_MARKERS = /BLOCKING|RISK NOTES|OUTSIDE PATHS|\bFAIL\b/;
const NONZERO_EXIT = /\bexit(?:\s+code)?\s*[:=]?\s*[1-9]\d*\b/i;

/**
 * Read the router's optional configuration for one profile. All values have safe defaults. The ds profile reads
 * ORCHESTRA_ROUTER_MODEL; the others read ORCHESTRA_ROUTER_<PROFILE>_MODEL. The old _STRONG pin still works as an
 * alias; the old _FAST pin is ignored (there is no second model any more). A per-model profile passes its own `defs`
 * (model, tiers, levels): its model is fixed by its id, so no env pin applies to it.
 */
export function readRouterConfig(env = process.env, profile = "ds", defs = null) {
  const number = (name, fallback) => {
    const raw = env[name];
    const n = raw == null || raw === "" ? NaN : Number(raw);
    return Number.isFinite(n) && n >= 0 ? n : fallback;
  };
  const fixed = defs && defs.model ? defs : null;
  if (!fixed) defs = PROFILE_DEFAULTS[profile] || PROFILE_DEFAULTS.ds;
  const prefix = profile === "ds" ? "ORCHESTRA_ROUTER" : `ORCHESTRA_ROUTER_${profile.toUpperCase()}`;
  const model = fixed ? fixed.model : env[`${prefix}_MODEL`] || env[`${prefix}_STRONG`] || defs.model;
  return {
    profile,
    model,
    closedLoop: isClosedLoop(model, env),
    classifier: env.ORCHESTRA_ROUTER_CLASSIFIER || "",
    softBudget: number("ORCHESTRA_ROUTER_SOFT_BUDGET", DEFAULT_SOFT_BUDGET),
    hardBudget: number("ORCHESTRA_ROUTER_HARD_BUDGET", DEFAULT_HARD_BUDGET),
    ctxPressure: number("ORCHESTRA_ROUTER_CTX_PRESSURE", DEFAULT_CTX_PRESSURE),
    tiers: defs.tiers,
    levels: defs.levels,
  };
}

/**
 * Whether a model's provider runs its own tool loop, so a thinking level only takes effect at the start of a user
 * turn. ORCHESTRA_ROUTER_CLOSED_LOOP overrides the provider list (comma separated; "none" for no provider).
 */
export function isClosedLoop(ref, env = process.env) {
  const raw = env.ORCHESTRA_ROUTER_CLOSED_LOOP;
  const list = (raw == null || raw === "" ? DEFAULT_CLOSED_LOOP : raw)
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s && s !== "none");
  const provider = splitModel(ref).provider;
  return !!provider && list.includes(provider);
}

/**
 * The profile config fitted to the physical model's real thinking ladder. A named profile's levels and tiers are
 * defaults written for a model family; the catalog model may lack some of them (Claude 5.5 has no `off`, DeepSeek V4
 * Pro only `off` and `high`). Pi would then clamp the level on its own, upward, and the router would report a level
 * that never ran. Levels become the intersection with what the model offers; when a tier no longer fits, the tiers
 * are rebuilt on the model's ladder the same way the per-model routers build theirs. A model that does not declare
 * `reasoning` (a test double) leaves the config unchanged.
 */
export function fitConfigToModel(config, model) {
  if (!model || typeof model !== "object" || model.reasoning === undefined) return config;
  const offered = supportedLevels(model);
  const own = Array.isArray(config.levels) && config.levels.length ? config.levels : LEVELS;
  const both = own.filter((l) => offered.includes(l));
  const levels = both.length ? both : offered;
  const tiers = config.tiers && TIERS.every((t) => levels.includes(config.tiers[t])) ? config.tiers : tiersForLevels(levels);
  return { ...config, levels, tiers };
}

/** One step down the thinking ladder: xhigh -> high -> medium -> low -> off. */
export function stepThinkingDown(level, steps = 1) {
  const i = LEVELS.indexOf(level);
  const from = i < 0 ? LEVELS.indexOf("medium") : i;
  return LEVELS[Math.max(0, from - Math.max(0, Number(steps) || 0))];
}

function atLeast(level, minimum) {
  return LEVELS.indexOf(level) >= LEVELS.indexOf(minimum) ? level : minimum;
}

function atMost(level, maximum) {
  return LEVELS.indexOf(level) <= LEVELS.indexOf(maximum) ? level : maximum;
}

/** Clamp a level to the nearest level a profile's physical models offer (frugal: never raise the request). */
export function clampLevel(level, levels) {
  const list = Array.isArray(levels) && levels.length ? levels : LEVELS;
  if (list.includes(level)) return level;
  let best = list[0];
  for (const l of list) {
    if (LEVELS.indexOf(l) <= LEVELS.indexOf(level)) best = l;
    else break;
  }
  return best;
}

function num(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

/** "provider/id" for a model reference: Pi passes catalog Model objects in request.previous/failed. */
function refOf(model) {
  if (!model) return "";
  if (typeof model === "string") return model;
  if (typeof model === "object" && model.id) return model.provider ? `${model.provider}/${model.id}` : String(model.id);
  return "";
}

/** previous/failed with the model normalised to a "provider/id" string (null when there is no model). */
function normalizeRoute(route) {
  if (!route || typeof route !== "object") return null;
  const model = refOf(route.model);
  return model ? { ...route, model } : null;
}

function splitModel(ref) {
  const s = refOf(ref);
  const i = s.indexOf("/");
  return i > 0 ? { provider: s.slice(0, i), id: s.slice(i + 1) } : { provider: "", id: s };
}

/** Sum assistant usage and turn context usage into cost, cache and pressure numbers. */
export function summarizeUsage(messages, contextUsage) {
  let cost = 0;
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  for (const message of Array.isArray(messages) ? messages : []) {
    if (!message || message.role !== "assistant") continue;
    const usage = message.usage || {};
    cost += num(usage.cost && usage.cost.total);
    input += num(usage.input);
    output += num(usage.output);
    cacheRead += num(usage.cacheRead != null ? usage.cacheRead : usage.cache_read);
  }
  const cacheTotal = input + cacheRead;
  const contextTokens = contextUsage && contextUsage.tokens != null ? num(contextUsage.tokens) : null;
  const contextWindow = contextUsage && contextUsage.contextWindow != null ? num(contextUsage.contextWindow) : null;
  let contextPct = 0;
  if (contextTokens != null && contextWindow > 0) contextPct = contextTokens / contextWindow;
  else if (contextUsage && contextUsage.percent != null) contextPct = num(contextUsage.percent) / 100;
  return {
    cost,
    input,
    output,
    cacheRead,
    cacheHitPct: cacheTotal > 0 ? (cacheRead / cacheTotal) * 100 : 0,
    contextTokens,
    contextWindow,
    contextPct,
  };
}

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) {
    if (content && typeof content === "object" && typeof content.text === "string") return content.text;
    return "";
  }
  const parts = [];
  for (const block of content) {
    if (!block) continue;
    if (typeof block === "string") parts.push(block);
    else if (typeof block.text === "string") parts.push(block.text);
    else if (typeof block.content === "string") parts.push(block.content);
  }
  return parts.join("\n");
}

function isToolResult(message) {
  return !!message && message.role === "toolResult";
}

function lastUserText(messages) {
  const list = Array.isArray(messages) ? messages : [];
  for (let i = list.length - 1; i >= 0; i--) {
    if (list[i] && list[i].role === "user") return textOf(list[i].content);
  }
  return "";
}

function lastToolResult(messages) {
  const list = Array.isArray(messages) ? messages : [];
  for (let i = list.length - 1; i >= 0; i--) {
    if (isToolResult(list[i])) return list[i];
  }
  return null;
}

function lastToolText(messages) {
  const message = lastToolResult(messages);
  return message ? textOf(message.content) : "";
}

/** One line describing the last tool call, for the classifier and for the /router view. */
export function toolSummary(messages) {
  const message = lastToolResult(messages);
  if (!message) return "";
  const line = textOf(message.content).split("\n").find((l) => l.trim()) || "";
  return `${message.toolName || "tool"}: ${line.trim()}`.slice(0, 240);
}

/** A tool result that demands attention: an error, a review marker, or a non-zero exit. */
export function isFailureToolText(text, isError = false) {
  if (isError) return true;
  const s = String(text || "");
  return FAILURE_MARKERS.test(s) || NONZERO_EXIT.test(s);
}

function isFailureToolResult(message) {
  return !!message && (message.isError === true || isFailureToolText(textOf(message.content)));
}

/** Trailing clean tool results since the last user message. */
export function countConsecutiveCleanTools(messages) {
  const list = Array.isArray(messages) ? messages : [];
  let count = 0;
  for (let i = list.length - 1; i >= 0; i--) {
    const message = list[i];
    if (!message) continue;
    if (message.role === "user") break;
    if (!isToolResult(message)) continue;
    if (isFailureToolResult(message)) break;
    count += 1;
  }
  return count;
}

function hasFailureInLastTool(messages) {
  const message = lastToolResult(messages);
  return !!message && isFailureToolResult(message);
}

function hasFailureSinceLastUser(messages) {
  const list = Array.isArray(messages) ? messages : [];
  for (let i = list.length - 1; i >= 0; i--) {
    const message = list[i];
    if (!message) continue;
    if (message.role === "user") break;
    if (isToolResult(message) && isFailureToolResult(message)) return true;
  }
  return false;
}

const HIGH_JUDGMENT =
  /(\barchitect\w*|\bdesign\w*|\bsecurity\w*|\bauth\w*|\boauth\w*|\boidc\w*|\bschema\w*|\bmigrat\w*|\bdatabase\w*|\bcnpg\w*|\bpostgres\w*|\bnetwork\w*|\bcilium\w*|\bwireguard\w*|\bdns\w*|\bcloudflare\w*|\btofu\w*|\bterraform\w*|\brollback\w*|\bincident\w*|\boutage\w*|\bdebug\w*|\bbug\w*|\breview\w*|\bdiff\w*|\bspec\w*|\bplan\w*|\brefactor\w*)/gi;
const ROUTINE_WORDS =
  /(\bstatus\w*|\blist\w*|\bcheck\w*|\bprove\w*|\bland\w*|\bclean\w*|\bartifact\w*|\bformat\w*|\blint\w*|\btypo\w*|\brename\w*|\bsummar\w*)/gi;
const TRIVIAL_PROMPT = /\b(status|list|clean|land|ok|yes|thanks|thank|commit|push|artifact)\b/i;

function keywordHits(text, re) {
  const seen = new Set();
  re.lastIndex = 0;
  let match;
  while ((match = re.exec(text)) !== null) {
    seen.add(match[0].toLowerCase());
    if (re.lastIndex === match.index) re.lastIndex += 1;
  }
  return seen.size;
}

/**
 * Zero-key, deterministic tier choice. Used directly, and as the fallback whenever a classifier is missing,
 * errors, or gives an unusable answer.
 */
export function classifyDeterministic(userText, lastToolText, virtualLevel) {
  const text = String(userText || "");
  const tool = String(lastToolText || "");
  if (isFailureToolText(tool)) return "deep";

  const high = keywordHits(text, HIGH_JUDGMENT);
  const routine = keywordHits(text, ROUTINE_WORDS);
  const longPrompt = text.trim().length > 400 || text.trim().split(/\s+/).length > 60;

  let tier = "standard";
  if (high >= 2 || (high >= 1 && longPrompt)) tier = "deep";
  else if (high === 1) tier = "standard";
  else if (routine > 0) tier = "routine";

  const trimmed = text.trim();
  if (virtualLevel === "low" && tier === "standard" && trimmed.length <= 160) tier = "routine";
  if (virtualLevel === "high" && tier === "standard") tier = "deep";
  return tier;
}

/**
 * Classifier-first tier choice for a user turn, with a deterministic fallback. `classify` is injected so the
 * offline suite can mock it; it receives `{ prompt, lastTool }` and should resolve to routine|standard|deep.
 */
export async function chooseTier(options = {}) {
  const userText = String(options.userText || "");
  const lastTool = String(options.lastToolText || "");
  const lastToolSummary = String(
    options.lastToolSummary || lastTool.split("\n").find((line) => line.trim()) || "",
  ).slice(0, 240);
  const virtualLevel = options.virtualLevel || "medium";

  // Fast paths never pay for a classifier call.
  if (isFailureToolText(lastTool)) {
    return { tier: "deep", classifierUsed: null, reason: "failure or review blocker in the last tool result" };
  }
  const trimmed = userText.trim();
  if (trimmed.length <= 80 && TRIVIAL_PROMPT.test(trimmed)) {
    return { tier: "routine", classifierUsed: null, reason: "short routine prompt" };
  }

  if (typeof options.classify === "function") {
    try {
      const answer = await options.classify({ prompt: trimmed.slice(0, 1200), lastTool: lastToolSummary });
      if (TIERS.includes(answer)) {
        return { tier: answer, classifierUsed: options.classifierRef || "classifier", reason: "classifier" };
      }
    } catch {
      /* any classifier problem falls through to the deterministic scorer; never fail the turn */
    }
  }

  const tier = classifyDeterministic(userText, lastTool, virtualLevel);
  return { tier, classifierUsed: null, reason: "deterministic fallback" };
}

// Frugal by default: reasoning is a cost, so spend it only where it pays. Each profile's `tiers` map gives the
// thinking level for routine/standard/deep work; the flash profile (workers) has no medium tier, so its deep maps
// straight to high. An explicit high virtual level still escalates a deep turn one notch where the profile allows.
// The model is always config.model: only the thinking level varies.
function baseRoute(tier, config, virtualLevel) {
  const model = config.model;
  if (tier === "direct") return { model, thinkingLevel: "off" };
  const tiers = (config && config.tiers) || { routine: "off", standard: "low", deep: "medium" };
  const level = tiers[tier] || tiers.standard || "low";
  if (tier === "deep" && virtualLevel === "high" && level === "medium") {
    return { model, thinkingLevel: "high" };
  }
  return { model, thinkingLevel: level };
}

function emptyState() {
  return {
    phase: "",
    tier: "",
    consecutiveCleanTools: 0,
    lastModel: "",
    lastThinking: "",
    lastReason: "",
    classifierUsed: false,
  };
}

function normalizeState(state) {
  const s = state && typeof state === "object" ? state : {};
  return {
    phase: typeof s.phase === "string" ? s.phase : "",
    tier: typeof s.tier === "string" ? s.tier : "",
    consecutiveCleanTools: Number.isFinite(s.consecutiveCleanTools) ? s.consecutiveCleanTools : 0,
    lastModel: typeof s.lastModel === "string" ? s.lastModel : "",
    lastThinking: typeof s.lastThinking === "string" ? s.lastThinking : "",
    lastReason: typeof s.lastReason === "string" ? s.lastReason : "",
    classifierUsed: s.classifierUsed != null ? s.classifierUsed : false,
  };
}

/**
 * Pure routing decision. `usage` comes from summarizeUsage; `config` from readRouterConfig; model names are
 * "provider/id" references. The route() wrapper resolves them to catalog entries and applies Pi's state rules.
 */
export function decideRoute(request = {}) {
  const config = { ...readRouterConfig({}), ...(request.config || {}) };
  const reason = request.reason || "user";
  const messages = Array.isArray(request.messages) ? request.messages : [];
  const usage = request.usage || {};
  const virtualLevel = request.virtualLevel || request.thinkingLevel || "medium";
  const previous = normalizeRoute(request.previous);
  const failed = normalizeRoute(request.failed);
  const stateIn = normalizeState(request.state);

  if (reason === "direct") {
    const direct = baseRoute("direct", config, virtualLevel);
    return {
      model: direct.model,
      thinkingLevel: direct.thinkingLevel,
      state: { ...emptyState(), phase: "direct", tier: "direct", lastModel: direct.model, lastThinking: direct.thinkingLevel, lastReason: "direct request (compaction or extension): same model, thinking off" },
    };
  }

  if (reason === "retry") {
    // A retry never changes the model, not even on a provider overload: pi backs off and retries the same route.
    let model;
    let thinkingLevel;
    let lastReason;
    if (failed && failed.model) {
      model = failed.model;
      thinkingLevel = failed.thinkingLevel || "medium";
      lastReason = "retry: same model as the failed request";
    } else {
      model = (previous && previous.model) || config.model;
      thinkingLevel = (previous && previous.thinkingLevel) || "medium";
      lastReason = "retry: no failed request, stick to the previous route";
    }
    const state = {
      ...stateIn,
      phase: "retry",
      tier: stateIn.tier || "standard",
      lastModel: model,
      lastThinking: thinkingLevel,
      lastReason,
      classifierUsed: stateIn.classifierUsed,
    };
    return { model, thinkingLevel, state };
  }

  if (reason === "continuation") {
    const sticky = (previous && previous.model) || stateIn.lastModel || config.model;
    let thinkingLevel = (previous && previous.thinkingLevel) || stateIn.lastThinking || "medium";
    const clean = countConsecutiveCleanTools(messages);
    const failure = hasFailureInLastTool(messages);
    let lastReason;

    if (config.closedLoop) {
      // The provider runs this turn's tool loop itself: a new level here would be recorded but never sent. Keep the
      // user-turn level so the session and /router report what the model really runs.
      const state = {
        ...stateIn,
        phase: "continuation",
        tier: stateIn.tier || "standard",
        consecutiveCleanTools: failure ? 0 : clean,
        lastModel: sticky,
        lastThinking: thinkingLevel,
        lastReason: `closed loop (${splitModel(sticky).provider}): the user-turn level ${thinkingLevel} holds until the next user message`,
        classifierUsed: stateIn.classifierUsed,
      };
      return { model: sticky, thinkingLevel, state };
    }

    if (failure) {
      const tiers = (config && config.tiers) || { standard: "low", deep: "medium" };
      // A turn that started routine only needs the standard level to look at a failure; any other turn needs deep.
      const minimum = stateIn.tier === "routine" ? tiers.standard : tiers.deep;
      thinkingLevel = atLeast(thinkingLevel, minimum);
      lastReason = `tool result needs attention: keep thinking at least ${minimum}`;
    } else if (clean >= 2) {
      thinkingLevel = stepThinkingDown(thinkingLevel);
      lastReason = `${clean} clean tool results: step thinking down to ${thinkingLevel}, same model`;
    } else {
      lastReason = "continuation: same model, thinking level unchanged";
    }

    // Budget/context pressure applies to continuation too, but never undoes a failure bump.
    const pressure = usage.cost >= config.softBudget || usage.contextPct >= config.ctxPressure;
    if (pressure && !failure && thinkingLevel !== "off") {
      thinkingLevel = stepThinkingDown(thinkingLevel);
      lastReason += `; pressure: thinking down to ${thinkingLevel}`;
    }

    const state = {
      ...stateIn,
      phase: "continuation",
      tier: stateIn.tier || "standard",
      consecutiveCleanTools: failure ? 0 : clean,
      lastModel: sticky,
      lastThinking: thinkingLevel,
      lastReason,
      classifierUsed: stateIn.classifierUsed,
    };
    return { model: sticky, thinkingLevel, state };
  }

  // user turn: tier is normally chosen by chooseTier (classifier-first), otherwise score it here.
  let tier;
  let classifierUsed = request.classifierUsed != null ? request.classifierUsed : null;
  let reasonText = "";
  if (TIERS.includes(request.tier)) {
    tier = request.tier;
    reasonText = request.tierReason || `${tier} turn`;
  } else {
    const userText = lastUserText(messages) || String(request.userText || "");
    const tool = lastToolText(messages) || String(request.lastToolText || "");
    if (hasFailureInLastTool(messages) || isFailureToolText(String(request.lastToolText || ""))) {
      tier = "deep";
      reasonText = "failure or review blocker in the last tool result";
    } else {
      const trimmed = userText.trim();
      if (trimmed.length <= 80 && TRIVIAL_PROMPT.test(trimmed)) {
        tier = "routine";
        reasonText = "short routine prompt";
      } else {
        tier = classifyDeterministic(userText, tool, virtualLevel);
        reasonText = `deterministic ${tier}`;
      }
    }
  }

  const base = baseRoute(tier, config, virtualLevel);
  const model = base.model;
  let thinkingLevel = base.thinkingLevel;
  let lastReason = reasonText;

  const sessionCost = num(usage.cost);
  const contextPct = num(usage.contextPct);

  // Spend and context pull the thinking level down; they never change the model.
  if (sessionCost >= config.hardBudget) {
    thinkingLevel = tier === "routine" ? "off" : atMost(thinkingLevel, "low");
    lastReason += `; hard budget: thinking capped at ${thinkingLevel}`;
  } else if (sessionCost >= config.softBudget || contextPct >= config.ctxPressure) {
    const pressureByContext = contextPct >= config.ctxPressure;
    const why = pressureByContext ? "context pressure" : "soft budget";
    if (tier === "deep") {
      // Frugal: pressure caps deep reasoning at medium; high is only for an explicit high virtual level.
      if (thinkingLevel === "high") {
        thinkingLevel = "medium";
        lastReason += `; ${why}: deep capped at medium`;
      }
    } else {
      thinkingLevel = stepThinkingDown(thinkingLevel);
      lastReason += `; ${why}: thinking down to ${thinkingLevel}`;
    }
  }

  const state = {
    phase: "user",
    tier,
    consecutiveCleanTools: 0,
    lastModel: model,
    lastThinking: thinkingLevel,
    lastReason,
    classifierUsed: !!classifierUsed,
  };
  return { model, thinkingLevel, state };
}

function modelRef(model) {
  return refOf(model);
}

/** Resolve a "provider/id" ref to its catalog Model, or null when the provider/model is absent. */
function resolveModel(ctx, ref) {
  const { provider, id } = splitModel(ref);
  return ctx && ctx.modelRegistry && ctx.modelRegistry.find ? ctx.modelRegistry.find(provider, id) || null : null;
}

function safeContextUsage(ctx) {
  try {
    return ctx && typeof ctx.getContextUsage === "function" ? ctx.getContextUsage() : null;
  } catch {
    return null;
  }
}

function preferClassifier(models) {
  const list = Array.isArray(models) ? models : [];
  return (
    list.find((m) => m && /clef-flash/i.test(String(m.id))) ||
    list.find((m) => m && /jev/i.test(String(m.id))) ||
    list[0] ||
    null
  );
}

async function findClassifier(ctx, config) {
  const registry = ctx && ctx.modelRegistry;
  if (!registry) return null;

  if (config.classifier) {
    const { provider, id } = splitModel(config.classifier);
    try {
      if (typeof registry.findOfType === "function") {
        const found = registry.findOfType("classifier", provider, id);
        if (found) return { model: found, ref: config.classifier };
      }
      if (typeof registry.getModelOfType === "function") {
        const found = await registry.getModelOfType("classifier", provider, id);
        if (found) return { model: found, ref: config.classifier };
      }
    } catch {
      return null;
    }
    return null;
  }

  try {
    if (typeof registry.getAvailableOfType === "function") {
      const model = preferClassifier(await registry.getAvailableOfType("classifier"));
      if (model) return { model, ref: modelRef(model) };
    }
  } catch {
    /* discovery is optional */
  }
  return null;
}

function stateChanged(previous, next) {
  if (!previous) return true;
  const a = normalizeState(previous);
  const b = normalizeState(next);
  return Object.keys(b).some((key) => a[key] !== b[key]);
}

// ---- One router per physical model ------------------------------------------------------------------------------
// Besides the named profiles, every reasoning chat model in the catalog gets its own router,
// orchestra/<provider>-<model>-auto, with the same frugal tiers mapped onto that model's own thinking levels. Pi has
// no catalog while extensions load, so the list is built at session_start from ctx.modelRegistry.getAvailable() and
// cached; the next start registers the cached list at load time, so `--model orchestra/<x>-auto` and resumed sessions
// find their model before session_start runs. ORCHESTRA_ROUTER_PER_MODEL=0 turns this off.

/** Router levels a catalog model offers, by Pi's rules: null in thinkingLevelMap is unsupported, xhigh only when mapped. */
export function supportedLevels(model) {
  if (!model || !model.reasoning) return ["off"];
  const map = model.thinkingLevelMap || {};
  return LEVELS.filter((level) => {
    const mapped = map[level];
    if (mapped === null) return false;
    if (level === "xhigh") return mapped !== undefined;
    return true;
  });
}

/** Frugal tiers on a model's own ladder: routine off, standard low, deep medium (high when it has no medium). */
export function tiersForLevels(levels) {
  const list = Array.isArray(levels) && levels.length ? levels : LEVELS;
  const pick = (...wanted) => wanted.find((l) => list.includes(l));
  return {
    routine: pick("off", "low") || list[0],
    standard: pick("low") || clampLevel("low", list),
    deep: pick("medium", "high") || list[list.length - 1],
  };
}

function slug(s) {
  return String(s || "")
    .toLowerCase()
    .replace(/[^a-z0-9.]+/g, "-")
    .replace(/^[-.]+|[-.]+$/g, "");
}

/** Virtual id for a catalog model: <provider>-<last id segment>-auto (the whole id when `full`). */
export function perModelId(model, full = false) {
  const id = String((model && model.id) || "");
  return `${slug(model && model.provider)}-${slug(full ? id : id.slice(id.lastIndexOf("/") + 1))}-auto`;
}

/**
 * Catalog models -> per-model router entries: JSON-safe, sorted by id, ids unique. Skips virtual models, non-chat
 * models, models without reasoning (there is no thinking level to route) and the orchestra provider itself. Two models
 * whose short ids collide both fall back to their full id.
 */
export function perModelEntries(models) {
  const list = (Array.isArray(models) ? models : []).filter(
    (m) =>
      m && m.id && m.provider && m.provider !== "orchestra" && m.api !== "pi-virtual" &&
      (m.type == null || m.type === "chat") && m.reasoning === true,
  );
  const counts = new Map();
  for (const m of list) counts.set(perModelId(m), (counts.get(perModelId(m)) || 0) + 1);
  const out = new Map();
  for (const m of list) {
    const id = counts.get(perModelId(m)) > 1 ? perModelId(m, true) : perModelId(m);
    if (Object.prototype.hasOwnProperty.call(PROFILE_BY_ID, id) || out.has(id)) continue;
    const levels = supportedLevels(m);
    const entry = { id, model: `${m.provider}/${m.id}`, name: `Orchestra Auto (${m.provider}/${m.id})`, levels, tiers: tiersForLevels(levels) };
    if (num(m.contextWindow) > 0) entry.contextWindow = num(m.contextWindow);
    if (num(m.maxTokens) > 0) entry.maxTokens = num(m.maxTokens);
    out.set(id, entry);
  }
  return [...out.values()].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/**
 * The entries to cache after a session_start: this session's entries for every provider that has available models
 * here, plus cached entries of providers this session cannot see (a worker started with --no-extensions, or without
 * that provider's key, must not erase the interactive catalog).
 */
export function mergePerModelEntries(cached, fresh) {
  const providerOf = (e) => String(e.model).slice(0, String(e.model).indexOf("/"));
  const seen = new Set(fresh.map(providerOf));
  const ids = new Set(fresh.map((e) => e.id));
  const kept = (Array.isArray(cached) ? cached : []).filter((e) => !seen.has(providerOf(e)) && !ids.has(e.id));
  return [...fresh, ...kept].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

export function perModelCachePath(env = process.env) {
  if (env.ORCHESTRA_ROUTER_CACHE) return env.ORCHESTRA_ROUTER_CACHE;
  return join(env.XDG_CACHE_HOME || join(env.HOME || homedir(), ".cache"), "orchestra", "router-models.json");
}

function validEntry(e) {
  return (
    !!e && typeof e.id === "string" && /^[a-z0-9.-]+-auto$/.test(e.id) &&
    !Object.prototype.hasOwnProperty.call(PROFILE_BY_ID, e.id) &&
    typeof e.model === "string" && e.model.indexOf("/") > 0 &&
    Array.isArray(e.levels) && e.levels.every((l) => LEVELS.includes(l)) &&
    !!e.tiers && TIERS.every((t) => LEVELS.includes(e.tiers[t]))
  );
}

/** Cached entries (only well-formed ones); [] when the cache is missing or unreadable. */
export function readPerModelCache(path) {
  try {
    const data = JSON.parse(readFileSync(path, "utf8"));
    return data && data.version === 1 && Array.isArray(data.entries) ? data.entries.filter(validEntry) : [];
  } catch {
    return [];
  }
}

function writePerModelCache(path, entries) {
  try {
    mkdirSync(dirname(path), { recursive: true });
    const tmp = `${path}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify({ version: 1, entries }, null, 1) + "\n");
    renameSync(tmp, path);
  } catch {
    /* best effort: a read-only home (a sandboxed worker) just keeps the old cache */
  }
}

function perModelEnabled(env = process.env) {
  return !/^(0|off|false|no)$/i.test(String(env.ORCHESTRA_ROUTER_PER_MODEL || "").trim());
}

function registerPerModelRouters(pi) {
  if (!perModelEnabled()) return;
  const path = perModelCachePath();
  const registered = new Map(); // id -> JSON of the entry it was registered with
  const register = (e) => {
    const config = readRouterConfig(process.env, e.id, { model: e.model, tiers: e.tiers, levels: e.levels });
    registerRouter(pi, { id: e.id, name: e.name || `Orchestra Auto (${e.model})`, config, contextWindow: e.contextWindow, maxTokens: e.maxTokens });
    registered.set(e.id, JSON.stringify(e));
  };
  for (const e of readPerModelCache(path)) {
    try {
      register(e);
    } catch {
      /* one bad entry never blocks the others */
    }
  }

  if (typeof pi.on !== "function") return;
  pi.on("session_start", async (_event, ctx) => {
    try {
      const registry = ctx && ctx.modelRegistry;
      if (!registry || typeof registry.getAvailable !== "function") return;
      const fresh = perModelEntries(registry.getAvailable());
      const wanted = new Set(fresh.map((e) => e.id));
      for (const e of fresh) if (registered.get(e.id) !== JSON.stringify(e)) register(e);
      // Unusable here (model gone, or its provider not loaded in this session): unregister, but the cache keeps
      // the entries of providers this session cannot see.
      for (const id of [...registered.keys()]) {
        if (wanted.has(id)) continue;
        try {
          pi.unregisterVirtualModel("orchestra", id);
        } catch {
          /* already gone */
        }
        registered.delete(id);
      }
      const cached = readPerModelCache(path);
      const next = mergePerModelEntries(cached, fresh);
      if (JSON.stringify(cached) !== JSON.stringify(next)) writePerModelCache(path, next);
    } catch {
      /* never break a session over the per-model list */
    }
  });
}

let lastSnapshot = null;

/** Register one router virtual model: `orchestra/<id>` on config.model, varying only the thinking level. */
function registerRouter(pi, { id, name, config, contextWindow, maxTokens }) {
  const limits = {};
  if (num(contextWindow) > 0) limits.contextWindow = num(contextWindow);
  if (num(maxTokens) > 0) limits.maxTokens = num(maxTokens);
  pi.registerVirtualModel({
    provider: "orchestra",
    id,
    name,
    thinkingLevels: ["low", "medium", "high"],
    ...limits,
    async route(request, ctx) {
      const messages = Array.isArray(request.messages) ? request.messages : [];
      const contextUsage = safeContextUsage(ctx);
      const usage = summarizeUsage(messages, contextUsage);
      const reason = request.reason || "user";
      const virtualLevel = request.thinkingLevel || "medium";

      let tier;
      let classifierUsed = null;
      let tierReason = "";
      let classifierLabel = null;
      if (reason === "user") {
        const classifier = await findClassifier(ctx, config);
        let classify;
        if (classifier) {
          classifierLabel = classifier.ref;
          classify = async ({ prompt, lastTool }) => {
            const result = await ctx.modelRegistry.classify(
              classifier.model,
              {
                state: { prompt, lastTool },
                questions: {
                  tier: {
                    type: "choice",
                    instructions:
                      "Pick the routing tier for this software-engineering turn. Routine is mechanical; " +
                      "standard needs ordinary judgment; deep needs architecture, security, data, network, " +
                      "migration, incident, or review-blocker judgment.",
                    criteria: {
                      routine: "Status, listing, formatting, linting, cleanup, or a trivial confirmation",
                      standard: "An ordinary implementation, small fix, or straightforward review",
                      deep: "Architecture, design, security, auth, schema, migration, database, network, infra, rollback, incident, hard debugging, or a blocking review",
                    },
                  },
                },
              },
              request.signal ? { signal: request.signal } : undefined,
            );
            const answer = result && result.stopReason === "stop" ? result.answers && result.answers.tier : null;
            return answer && answer.type === "choice" ? answer.choice : undefined;
          };
        }
        const choice = await chooseTier({
          userText: lastUserText(messages),
          lastToolText: lastToolText(messages),
          lastToolSummary: toolSummary(messages),
          virtualLevel,
          classify,
          classifierRef: classifierLabel,
        });
        tier = choice.tier;
        classifierUsed = choice.classifierUsed;
        tierReason = choice.classifierUsed ? "classifier-chosen tier" : choice.reason;
      }

      // Resolve the model first: the levels and tiers come from what it really offers. There is no alternate to fall
      // back to: a missing model is a setup error.
      const model = resolveModel(ctx, config.model);
      if (!model) {
        throw new Error(`orchestra/${id}: ${config.model} is not in the catalog (provider not loaded or no credentials)`);
      }
      const fitted = fitConfigToModel(config, model);

      const decision = decideRoute({
        reason,
        messages,
        previous: request.previous,
        failed: request.failed,
        thinkingLevel: virtualLevel,
        virtualLevel,
        tier,
        tierReason,
        classifierUsed,
        usage,
        state: request.state,
        config: fitted,
      });

      // Clamp to what the physical model offers, frugally (never above the decision), and record the level that is
      // really sent, so the session state and /router never claim a level the model did not run.
      const thinkingLevel = clampLevel(decision.thinkingLevel, fitted.levels);
      if (decision.state) decision.state.lastThinking = thinkingLevel;

      lastSnapshot = {
        profile: config.profile,
        model: decision.model,
        thinkingLevel,
        reason: decision.state && decision.state.lastReason,
        tier: decision.state && decision.state.tier,
        usage,
        classifier: decision.state && decision.state.classifierUsed ? classifierLabel || "classifier" : null,
        config: fitted,
      };

      const result = { model, thinkingLevel };
      if (reason !== "direct" && decision.state && stateChanged(request.state, decision.state)) result.state = decision.state;
      return result;
    },
  });
}

export default function (pi) {
  for (const [id, profileKey] of Object.entries(PROFILE_BY_ID)) {
    const name = id === "auto" ? "Orchestra Auto" : `Orchestra Auto (${profileKey})`;
    registerRouter(pi, { id, name, config: readRouterConfig(process.env, profileKey) });
  }
  registerPerModelRouters(pi);

  pi.registerCommand("router", {
    description: "Show the last orchestra/auto route, spend, context, cache and classifier",
    handler: async (_args, ctx) => {
      if (!lastSnapshot) {
        if (ctx && ctx.ui) ctx.ui.notify("orchestra/auto has not routed a request yet", "info");
        return;
      }
      const s = lastSnapshot;
      const money = (n) => `$${num(n).toFixed(2)}`;
      const pct = (n) => `${Math.round(num(n) * 100)}%`;
      const text =
        `router: [${s.profile || "?"}] ${s.model}:${s.thinkingLevel} (${s.tier || "?"}) · ${s.reason || "no reason recorded"} · ` +
        (s.config.closedLoop ? "closed loop: level set per user turn · " : "") +
        `spend ${money(s.usage.cost)} vs soft ${money(s.config.softBudget)} / hard ${money(s.config.hardBudget)} · ` +
        `context ${pct(s.usage.contextPct)} · cache hit ${Math.round(num(s.usage.cacheHitPct))}% · ` +
        `classifier ${s.classifier || "deterministic fallback"}`;
      if (ctx && ctx.ui) ctx.ui.notify(text, "info");
    },
  });
}
