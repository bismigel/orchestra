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
const FAILURE_MARKERS = /BLOCKING|RISK NOTES|OUTSIDE PATHS|\bFAIL\b/;
const NONZERO_EXIT = /\bexit(?:\s+code)?\s*[:=]?\s*[1-9]\d*\b/i;

/**
 * Read the router's optional configuration for one profile. All values have safe defaults. The ds profile reads
 * ORCHESTRA_ROUTER_MODEL; the others read ORCHESTRA_ROUTER_<PROFILE>_MODEL. The old _STRONG pin still works as an
 * alias; the old _FAST pin is ignored (there is no second model any more).
 */
export function readRouterConfig(env = process.env, profile = "ds") {
  const number = (name, fallback) => {
    const raw = env[name];
    const n = raw == null || raw === "" ? NaN : Number(raw);
    return Number.isFinite(n) && n >= 0 ? n : fallback;
  };
  const defs = PROFILE_DEFAULTS[profile] || PROFILE_DEFAULTS.ds;
  const prefix = profile === "ds" ? "ORCHESTRA_ROUTER" : `ORCHESTRA_ROUTER_${profile.toUpperCase()}`;
  return {
    profile,
    model: env[`${prefix}_MODEL`] || env[`${prefix}_STRONG`] || defs.model,
    classifier: env.ORCHESTRA_ROUTER_CLASSIFIER || "",
    softBudget: number("ORCHESTRA_ROUTER_SOFT_BUDGET", DEFAULT_SOFT_BUDGET),
    hardBudget: number("ORCHESTRA_ROUTER_HARD_BUDGET", DEFAULT_HARD_BUDGET),
    ctxPressure: number("ORCHESTRA_ROUTER_CTX_PRESSURE", DEFAULT_CTX_PRESSURE),
    tiers: defs.tiers,
    levels: defs.levels,
  };
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

let lastSnapshot = null;

export default function (pi) {
  for (const [id, profileKey] of Object.entries(PROFILE_BY_ID)) {
    const config = readRouterConfig(process.env, profileKey);

    pi.registerVirtualModel({
      provider: "orchestra",
      id,
      name: id === "auto" ? "Orchestra Auto" : `Orchestra Auto (${profileKey})`,
      thinkingLevels: ["low", "medium", "high"],
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
          config,
        });

        // Clamp to what this profile's physical models actually offer (the flash profile has no medium tier).
        const thinkingLevel = clampLevel(decision.thinkingLevel, config.levels);

        // Resolve the chosen model. There is no alternate to fall back to: a missing model is a setup error.
        const model = resolveModel(ctx, decision.model);
        if (!model) {
          throw new Error(`orchestra/${id}: ${decision.model} is not in the catalog (provider not loaded or no credentials)`);
        }

        lastSnapshot = {
          profile: config.profile,
          model: decision.model,
          thinkingLevel,
          reason: decision.state && decision.state.lastReason,
          tier: decision.state && decision.state.tier,
          usage,
          classifier: decision.state && decision.state.classifierUsed ? classifierLabel || "classifier" : null,
          config,
        };

        const result = { model, thinkingLevel };
        if (reason !== "direct" && decision.state && stateChanged(request.state, decision.state)) result.state = decision.state;
        return result;
      },
    });
  }

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
        `spend ${money(s.usage.cost)} vs soft ${money(s.config.softBudget)} / hard ${money(s.config.hardBudget)} · ` +
        `context ${pct(s.usage.contextPct)} · cache hit ${Math.round(num(s.usage.cacheHitPct))}% · ` +
        `classifier ${s.classifier || "deterministic fallback"}`;
      if (ctx && ctx.ui) ctx.ui.notify(text, "info");
    },
  });
}
