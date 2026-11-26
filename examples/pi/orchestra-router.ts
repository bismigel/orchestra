// orchestra/auto: a Pi virtual model that routes each request to a physical model and thinking level.
//
// The orchestrating model is expensive; most worker turns are not. This router sends obvious work to the fast
// model with little or no thinking, keeps hard/risky work on the strong model, and never changes the physical
// model mid-turn (the prompt cache and thinking signatures stay valid). Session spend and context usage are
// respected, and an optional classifier model can make the tier call before the deterministic scorer does.
//
// Install: link this file into ~/.pi/agent/extensions/ (or start pi with `-e ./orchestra-router.ts`) and select
// `orchestra/auto`. In orchestra-worker, set ORCHESTRA_MODEL=orchestra/auto and ORCHESTRA_ROUTER_EXT=<this file>.
//
// The helpers below are pure and exported so the offline suite (tests/router.sh) can exercise them with `node`,
// without a model or a Pi runtime. Keep this file plain ESM JavaScript: Pi loads it as TypeScript, node imports it
// directly for tests.
// @ts-nocheck

const DEFAULT_STRONG = "deepseek/deepseek-v4-pro";
const DEFAULT_FAST = "deepseek/deepseek-flash";
const DEFAULT_SOFT_BUDGET = 1.5;
const DEFAULT_HARD_BUDGET = 4.0;
const DEFAULT_CTX_PRESSURE = 0.7;

const LEVELS = ["off", "low", "medium", "high", "xhigh"];
const TIERS = ["routine", "standard", "deep"];
const FAILURE_MARKERS = /BLOCKING|RISK NOTES|OUTSIDE PATHS|\bFAIL\b/;
const NONZERO_EXIT = /\bexit(?:\s+code)?\s*[:=]?\s*[1-9]\d*\b/i;

/** Read the router's optional configuration. All values have safe defaults. */
export function readRouterConfig(env = process.env) {
  const number = (name, fallback) => {
    const raw = env[name];
    const n = raw == null || raw === "" ? NaN : Number(raw);
    return Number.isFinite(n) && n >= 0 ? n : fallback;
  };
  return {
    strong: env.ORCHESTRA_ROUTER_STRONG || DEFAULT_STRONG,
    fast: env.ORCHESTRA_ROUTER_FAST || DEFAULT_FAST,
    classifier: env.ORCHESTRA_ROUTER_CLASSIFIER || "",
    softBudget: number("ORCHESTRA_ROUTER_SOFT_BUDGET", DEFAULT_SOFT_BUDGET),
    hardBudget: number("ORCHESTRA_ROUTER_HARD_BUDGET", DEFAULT_HARD_BUDGET),
    ctxPressure: number("ORCHESTRA_ROUTER_CTX_PRESSURE", DEFAULT_CTX_PRESSURE),
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

function baseRoute(tier, config, virtualLevel) {
  if (tier === "direct") return { model: config.fast, thinkingLevel: "off" };
  if (tier === "routine") return { model: config.fast, thinkingLevel: "low" };
  if (tier === "deep") {
    return { model: config.strong, thinkingLevel: virtualLevel === "high" ? "xhigh" : "high" };
  }
  return { model: config.strong, thinkingLevel: "medium" };
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
      state: { ...emptyState(), phase: "direct", tier: "direct", lastModel: direct.model, lastThinking: direct.thinkingLevel, lastReason: "direct request (compaction or extension): fast, thinking off" },
    };
  }

  if (reason === "retry") {
    const error = failed && failed.message && failed.message.errorMessage;
    let model;
    let thinkingLevel;
    let lastReason;
    if (failed && failed.model && isOverloadError(error)) {
      model = failed.model === config.strong ? config.fast : config.strong;
      thinkingLevel = "medium";
      lastReason = "retry: provider overload, failed over to alternate model";
    } else if (failed && failed.model) {
      model = failed.model;
      thinkingLevel = failed.thinkingLevel || "medium";
      lastReason = "retry: sticky on the failed model";
    } else {
      model = (previous && previous.model) || config.fast;
      thinkingLevel = (previous && previous.thinkingLevel) || "medium";
      lastReason = "retry: no failed model, stick to the previous route";
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
    const sticky = (previous && previous.model) || stateIn.lastModel || config.strong;
    let thinkingLevel = (previous && previous.thinkingLevel) || stateIn.lastThinking || "medium";
    const clean = countConsecutiveCleanTools(messages);
    const failure = hasFailureSinceLastUser(messages);
    let lastReason;

    if (failure) {
      const minimum = sticky === config.strong ? "high" : "medium";
      thinkingLevel = atLeast(thinkingLevel, minimum);
      lastReason = `tool result needs attention: keep thinking at least ${minimum}`;
    } else if (clean >= 3) {
      thinkingLevel = stepThinkingDown(thinkingLevel);
      lastReason = `${clean} clean tool results: step thinking down to ${thinkingLevel}, same model`;
    } else {
      lastReason = "continuation: sticky model to preserve the prompt cache";
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
  let model = base.model;
  let thinkingLevel = base.thinkingLevel;
  let lastReason = reasonText;

  const sessionCost = num(usage.cost);
  const contextPct = num(usage.contextPct);
  const contextTokens = usage.contextTokens != null ? num(usage.contextTokens) : 0;
  const prevStrong = !!(previous && previous.model === config.strong);

  if (sessionCost >= config.hardBudget) {
    if (tier === "deep") {
      model = config.strong;
      thinkingLevel = "medium";
      lastReason += `; hard budget: strong reserved for deep turns, thinking medium`;
    } else if (tier === "standard" && prevStrong && contextTokens > 40000) {
      // Cache hysteresis: a strong prompt cache is worth more than the one-turn saving.
      model = config.strong;
      thinkingLevel = "medium";
      lastReason += `; hard budget: cache hysteresis keeps strong while context is large`;
    } else {
      model = config.fast;
      thinkingLevel = tier === "standard" ? "medium" : "low";
      lastReason += `; hard budget: routine/standard on the fast model (${thinkingLevel})`;
    }
  } else if (sessionCost >= config.softBudget || contextPct >= config.ctxPressure) {
    const pressureByContext = contextPct >= config.ctxPressure;
    const why = pressureByContext ? "context pressure" : "soft budget";
    if (tier === "deep") {
      // Deep turns are critical: pressure only removes the optional xhigh posture, never the high floor.
      if (thinkingLevel === "xhigh") {
        thinkingLevel = "high";
        lastReason += `; ${why}: deep capped at high (no xhigh)`;
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

/** Provider errors that are worth failing over for. */
export function isOverloadError(message) {
  return /429|503|529|overload|rate.?limit|capacity|temporarily unavailable/i.test(String(message || ""));
}

function modelRef(model) {
  return refOf(model);
}

function resolveModel(ctx, ref) {
  const { provider, id } = splitModel(ref);
  const found = ctx && ctx.modelRegistry && ctx.modelRegistry.find ? ctx.modelRegistry.find(provider, id) : null;
  if (!found) throw new Error(`orchestra/auto: physical model ${refOf(ref) || JSON.stringify(ref)} is not in the catalog`);
  return found;
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
  const config = readRouterConfig();

  pi.registerVirtualModel({
    provider: "orchestra",
    id: "auto",
    name: "Orchestra Auto",
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

      const model = resolveModel(ctx, decision.model);
      lastSnapshot = {
        model: decision.model,
        thinkingLevel: decision.thinkingLevel,
        reason: decision.state && decision.state.lastReason,
        tier: decision.state && decision.state.tier,
        usage,
        classifier: decision.state && decision.state.classifierUsed ? classifierLabel || "classifier" : null,
        config,
      };

      const result = { model, thinkingLevel: decision.thinkingLevel };
      if (reason !== "direct" && decision.state && stateChanged(request.state, decision.state)) result.state = decision.state;
      return result;
    },
  });

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
        `router: ${s.model}:${s.thinkingLevel} (${s.tier || "?"}) · ${s.reason || "no reason recorded"} · ` +
        `spend ${money(s.usage.cost)} vs soft ${money(s.config.softBudget)} / hard ${money(s.config.hardBudget)} · ` +
        `context ${pct(s.usage.contextPct)} · cache hit ${Math.round(num(s.usage.cacheHitPct))}% · ` +
        `classifier ${s.classifier || "deterministic fallback"}`;
      if (ctx && ctx.ui) ctx.ui.notify(text, "info");
    },
  });
}
