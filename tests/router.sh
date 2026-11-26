#!/usr/bin/env bash
# orchestra/auto router: offline unit tests for the pure routing helpers, and orchestra-worker integration for
# ORCHESTRA_ROUTER_EXT. No model calls and no network.
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W="$ROOT/bin/orchestra-worker"
ROUTER="$ROOT/examples/pi/orchestra-router.ts"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }

# ---- Part 1: pure helpers, imported by node directly (type stripping) -------------------------------------------
export ROUTER
# Node >= 22.18 imports .ts directly. Older nodes do not know the extension: the file is plain ESM JavaScript, so
# the same test imports an identical .mjs copy there (nothing is generated or changed in the repository).
if ! node --input-type=module -e 'import { pathToFileURL } from "node:url"; await import(pathToFileURL(process.env.ROUTER).href)' >/dev/null 2>&1; then
  cp "$ROUTER" "$TMP/orchestra-router.mjs"
  export ROUTER="$TMP/orchestra-router.mjs"
fi
out=$(node --input-type=module - <<'JS' 2>&1
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const m = await import(pathToFileURL(process.env.ROUTER).href);
let pass = 0;
const failures = [];
const ok = (name) => { pass += 1; console.log("ok   " + name); };
const bad = (name, detail) => { failures.push(name); console.log("FAIL " + name + (detail ? ": " + detail : "")); };
async function t(name, fn) {
  try { await fn(); ok(name); } catch (e) { bad(name, e && e.message ? e.message : String(e)); }
}
const eq = (a, b, what = "value") => assert.deepEqual(a, b, `${what}: got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`);
const user = (text) => ({ role: "user", content: text });
const tool = (text, extra = {}) => ({ role: "toolResult", toolName: "bash", content: text, ...extra });
const assistant = (usage) => ({ role: "assistant", content: "ok", usage });
const cfg = { strong: "p/strong", fast: "p/fast", softBudget: 1.5, hardBudget: 4, ctxPressure: 0.7 };
const prevStrongHigh = { model: cfg.strong, thinkingLevel: "high" };

await t("direct routes to fast:off", () => {
  const r = m.decideRoute({ reason: "direct", config: cfg });
  eq(r.model, cfg.fast, "model");
  eq(r.thinkingLevel, "off", "thinking");
});
await t("defaults are the documented physical models", () => {
  const r = m.decideRoute({ reason: "direct" });
  eq(r.model, "deepseek/deepseek-flash", "default fast");
  const s = m.decideRoute({ reason: "user", messages: [user("add a helper")] });
  eq(s.model, "deepseek/deepseek-v4-pro", "default strong");
});
await t("routine prompt routes to fast:low", () => {
  const r = m.decideRoute({ reason: "user", messages: [user("status please")], config: cfg });
  eq(r.model, cfg.fast, "model");
  eq(r.thinkingLevel, "low", "thinking");
});
await t("standard prompt routes to strong:medium", () => {
  const r = m.decideRoute({ reason: "user", messages: [user("add a small helper function in src/greet.ts")], config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "medium", "thinking");
});
await t("deep prompt routes to strong:high", () => {
  const r = m.decideRoute({ reason: "user", messages: [user("investigate the security incident across the network and cnpg")], config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "high", "thinking");
});
await t("deep prompt uses xhigh when the virtual level is high", () => {
  const r = m.decideRoute({ reason: "user", messages: [user("investigate the security incident across the network and cnpg")], virtualLevel: "high", config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "xhigh", "thinking");
});
await t("classifyDeterministic scores routine and high-judgment words", () => {
  eq(m.classifyDeterministic("please lint and format this", "", "medium"), "routine", "routine");
  eq(m.classifyDeterministic("look at the schema and the migration", "", "medium"), "deep", "two high hits");
  eq(m.classifyDeterministic("check the auth path", "", "medium"), "standard", "one high hit");
});
await t("virtual low biases a short standard prompt to routine; high biases it to deep", () => {
  eq(m.classifyDeterministic("adjust the parser", "", "low"), "routine", "low");
  eq(m.classifyDeterministic("adjust the parser", "", "high"), "deep", "high");
});

await t("continuation stays sticky and steps thinking down after three clean tools", () => {
  const messages = [user("go"), tool("exit 0"), tool("ok"), tool("done")];
  const r = m.decideRoute({ reason: "continuation", previous: prevStrongHigh, messages, config: cfg, state: { tier: "standard", consecutiveCleanTools: 2 } });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "medium", "thinking");
  eq(r.state.consecutiveCleanTools, 3, "clean tools");
});
for (const [label, text] of [["BLOCKING", "BLOCKING: choose a database"], ["RISK NOTES", "RISK NOTES\nrotate the key"], ["FAIL", "FAIL test_parser"], ["non-zero exit", "command failed: exit 2"]]) {
  t(`continuation resets and keeps thinking up on ${label}`, () => {
    const messages = [user("go"), tool("exit 0"), tool(text)];
    const r = m.decideRoute({ reason: "continuation", previous: { model: cfg.strong, thinkingLevel: "low" }, messages, config: cfg });
    eq(r.model, cfg.strong, "model stays");
    eq(r.thinkingLevel, "high", "strong thinking at least high");
    eq(r.state.consecutiveCleanTools, 0, "clean tools reset");
  });
}
await t("continuation keeps fast thinking at least medium after a failure", () => {
  const messages = [user("go"), tool("exit 1")];
  const r = m.decideRoute({ reason: "continuation", previous: { model: cfg.fast, thinkingLevel: "low" }, messages, config: cfg });
  eq(r.thinkingLevel, "medium", "fast thinking at least medium");
});

await t("retry fails strong over to fast medium on an overload error", () => {
  const r = m.decideRoute({ reason: "retry", failed: { model: cfg.strong, thinkingLevel: "high", message: { errorMessage: "HTTP 429 rate limit" } }, config: cfg });
  eq(r.model, cfg.fast, "model");
  eq(r.thinkingLevel, "medium", "thinking");
});
await t("retry fails fast over to strong medium on 503 overload", () => {
  const r = m.decideRoute({ reason: "retry", failed: { model: cfg.fast, thinkingLevel: "low", message: { errorMessage: "provider overloaded (503)" } }, config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "medium", "thinking");
});
await t("retry stays sticky on a non-overload error", () => {
  const r = m.decideRoute({ reason: "retry", failed: { model: cfg.strong, thinkingLevel: "high", message: { errorMessage: "invalid api key" } }, config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "high", "thinking");
});
await t("isOverloadError matches the documented family only", () => {
  for (const s of ["429", "503", "529", "overloaded", "rate-limit", "rate limit", "capacity", "temporarily unavailable"]) eq(m.isOverloadError(s), true, s);
  eq(m.isOverloadError("invalid api key"), false, "api key");
});

await t("soft budget steps a standard turn down one notch", () => {
  const r = m.decideRoute({ reason: "user", tier: "standard", messages: [user("implement the helper")], usage: { cost: 2, contextPct: 0.2 }, config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "low", "thinking");
});
await t("context pressure steps a standard turn down one notch", () => {
  const r = m.decideRoute({ reason: "user", tier: "standard", messages: [user("implement the helper")], usage: { cost: 0.2, contextPct: 0.8 }, config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "low", "thinking");
});
await t("soft budget leaves a deep turn alone", () => {
  const r = m.decideRoute({ reason: "user", tier: "deep", messages: [user("security review")], usage: { cost: 2, contextPct: 0.2 }, config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "high", "thinking");
});
await await t("soft budget caps a deep xhigh turn at high", () => {
  const r = m.decideRoute({ reason: "user", tier: "deep", messages: [user("security review")], virtualLevel: "high", usage: { cost: 2, contextPct: 0.2 }, config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "high", "thinking");
});
await t("context pressure caps a deep xhigh turn at high", () => {
  const r = m.decideRoute({ reason: "user", tier: "deep", messages: [user("security review")], virtualLevel: "high", usage: { cost: 0.2, contextPct: 0.8 }, config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "high", "thinking");
});
await t("hard budget demotes standard to fast:medium", () => {
  const r = m.decideRoute({ reason: "user", tier: "standard", messages: [user("implement the helper")], usage: { cost: 5, contextPct: 0.2 }, config: cfg });
  eq(r.model, cfg.fast, "model");
  eq(r.thinkingLevel, "medium", "thinking");
});
await t("hard budget demotes routine to fast:low", () => {
  const r = m.decideRoute({ reason: "user", tier: "routine", messages: [user("status")], usage: { cost: 5, contextPct: 0.2 }, config: cfg });
  eq(r.model, cfg.fast, "model");
  eq(r.thinkingLevel, "low", "thinking");
});
await t("hard budget preserves strong for deep turns", () => {
  const r = m.decideRoute({ reason: "user", tier: "deep", messages: [user("security review")], virtualLevel: "high", usage: { cost: 5, contextPct: 0.2 }, config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "medium", "thinking");
});
await t("cache hysteresis keeps strong for a borderline standard turn with large context", () => {
  const r = m.decideRoute({ reason: "user", tier: "standard", previous: prevStrongHigh, messages: [user("implement the helper")], usage: { cost: 5, contextPct: 0.25, contextTokens: 50000 }, config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "medium", "thinking");
});
await t("cache hysteresis does not keep strong for a clear routine turn", () => {
  const r = m.decideRoute({ reason: "user", tier: "routine", previous: prevStrongHigh, messages: [user("status")], usage: { cost: 5, contextPct: 0.25, contextTokens: 50000 }, config: cfg });
  eq(r.model, cfg.fast, "model");
  eq(r.thinkingLevel, "low", "thinking");
});

await t("summarizeUsage sums cost and tokens, cache hit and context percent", () => {
  const u = m.summarizeUsage(
    [assistant({ input: 100, output: 50, cacheRead: 300, cost: { total: 0.5 } }), user("ignored"), assistant({ input: 10, output: 5, cost: { total: 0.25 } })],
    { tokens: 60000, contextWindow: 100000 },
  );
  eq(Math.round(u.cost * 100) / 100, 0.75, "cost");
  eq(u.input, 110, "input");
  eq(u.output, 55, "output");
  eq(u.cacheRead, 300, "cache read");
  eq(Math.round(u.cacheHitPct), 73, "cache hit percent");
  eq(u.contextPct, 0.6, "context percent");
});
await t("stepThinkingDown walks the ladder and stops at off", () => {
  eq(m.stepThinkingDown("xhigh"), "high", "xhigh");
  eq(m.stepThinkingDown("high"), "medium", "high");
  eq(m.stepThinkingDown("medium"), "low", "medium");
  eq(m.stepThinkingDown("low"), "off", "low");
  eq(m.stepThinkingDown("off"), "off", "off");
});

await t("classifier answer is used when available", async () => {
  let calls = 0;
  let seenTool = null;
  const r = await m.chooseTier({
    userText: "please do the thing we discussed",
    lastToolText: "all tests pass\nmore output",
    virtualLevel: "medium",
    classifierRef: "fake/clef-flash",
    classify: async ({ lastTool }) => { calls += 1; seenTool = lastTool; return "deep"; },
  });
  eq(calls, 1, "classifier calls");
  eq(seenTool, "all tests pass", "classifier saw a one-line tool summary");
  eq(r.tier, "deep", "tier");
  eq(r.classifierUsed, "fake/clef-flash", "classifier used");
});
await t("classifier failure falls back cleanly to deterministic routing", async () => {
  const r = await m.chooseTier({
    userText: "refactor the schema and the postgres migration",
    lastToolText: "",
    virtualLevel: "medium",
    classify: async () => { throw new Error("classifier is down"); },
  });
  eq(r.tier, "deep", "tier");
  eq(r.classifierUsed, null, "no classifier");
});
await t("a short routine prompt never calls the classifier", async () => {
  let calls = 0;
  const r = await m.chooseTier({
    userText: "status",
    lastToolText: "",
    virtualLevel: "medium",
    classify: async () => { calls += 1; return "deep"; },
  });
  eq(calls, 0, "classifier calls");
  eq(r.tier, "routine", "tier");
});
await t("a blocking tool result is deep before any classifier call", async () => {
  let calls = 0;
  const r = await m.chooseTier({
    userText: "what next?",
    lastToolText: "RISK NOTES: rotate the token",
    virtualLevel: "medium",
    classify: async () => { calls += 1; return "routine"; },
  });
  eq(calls, 0, "classifier calls");
  eq(r.tier, "deep", "tier");
});

// Pi passes catalog Model objects (not "provider/id" strings) in request.previous.model and request.failed.model.
const modelObj = (ref) => { const [provider, id] = ref.split("/"); return { provider, id, name: id, api: "x" }; };
await t("continuation accepts a Model object in previous and stays sticky", () => {
  const r = m.decideRoute({ reason: "continuation", previous: { model: modelObj(cfg.strong), thinkingLevel: "high" }, messages: [user("go")], config: cfg });
  eq(r.model, cfg.strong, "model");
  eq(r.thinkingLevel, "high", "thinking");
  eq(r.state.lastModel, cfg.strong, "state stores the string ref");
});
await t("retry accepts a Model object in failed and fails over on overload", () => {
  const r = m.decideRoute({ reason: "retry", failed: { model: modelObj(cfg.strong), thinkingLevel: "high", message: { errorMessage: "HTTP 529 overloaded" } }, config: cfg });
  eq(r.model, cfg.fast, "model");
});
await t("retry accepts a Model object in failed and stays sticky otherwise", () => {
  const r = m.decideRoute({ reason: "retry", failed: { model: modelObj(cfg.fast), thinkingLevel: "low", message: { errorMessage: "invalid api key" } }, config: cfg });
  eq(r.model, cfg.fast, "model");
  eq(r.thinkingLevel, "low", "thinking");
});
await t("user turn with a Model object in previous keeps cache hysteresis", () => {
  const r = m.decideRoute({ reason: "user", tier: "standard", previous: { model: modelObj(cfg.strong), thinkingLevel: "high" }, messages: [user("implement the helper")], usage: { cost: 5, contextPct: 0.25, contextTokens: 50000 }, config: cfg });
  eq(r.model, cfg.strong, "model");
});
await t("route() resolves Model objects from Pi's previous/failed through the registry", async () => {
  const saved = { s: process.env.ORCHESTRA_ROUTER_STRONG, f: process.env.ORCHESTRA_ROUTER_FAST };
  process.env.ORCHESTRA_ROUTER_STRONG = cfg.strong;
  process.env.ORCHESTRA_ROUTER_FAST = cfg.fast;
  let vm;
  try {
    m.default({ registerVirtualModel: (d) => { vm = d; }, registerCommand: () => {} });
  } finally {
    if (saved.s === undefined) delete process.env.ORCHESTRA_ROUTER_STRONG; else process.env.ORCHESTRA_ROUTER_STRONG = saved.s;
    if (saved.f === undefined) delete process.env.ORCHESTRA_ROUTER_FAST; else process.env.ORCHESTRA_ROUTER_FAST = saved.f;
  }
  const catalog = [modelObj(cfg.strong), modelObj(cfg.fast)];
  const ctx = { modelRegistry: { find: (p, id) => catalog.find((c) => c.provider === p && c.id === id) } };
  const cont = await vm.route({ reason: "continuation", thinkingLevel: "medium", messages: [user("go")], previous: { model: catalog[0], thinkingLevel: "high" } }, ctx);
  eq(cont.model, catalog[0], "continuation model");
  const retry = await vm.route({ reason: "retry", thinkingLevel: "medium", messages: [user("go")], failed: { model: catalog[1], thinkingLevel: "low", message: { errorMessage: "invalid api key" } } }, ctx);
  eq(retry.model, catalog[1], "retry model");
});
console.log(`part1: ${pass} passed, ${failures.length} failed`);
if (failures.length) process.exit(1);
JS
); node_rc=$?
printf '%s\n' "$out"
p=$(sed -n 's/^part1: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\1/p' <<<"$out")
f=$(sed -n 's/^part1: \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed$/\2/p' <<<"$out")
if [ -n "$p" ]; then pass=$((pass + p)); fail=$((fail + f)); else bad "part 1 did not report its results (node rc $node_rc)"; fi
[ "$node_rc" = 0 ] || bad "part 1 node exited $node_rc"

# ---- Part 2: orchestra-worker + ORCHESTRA_ROUTER_EXT -------------------------------------------------------------
git init -q -b main "$TMP/repo" && git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cp "$ROOT/examples/hello/spec.md" "$TMP/repo/spec.md"
export XDG_CONFIG_HOME="$TMP/cfg" ORCHESTRA_TEST_ROOT="$ROOT"
export ORCHESTRA_MODEL=orchestra/auto ORCHESTRA_ALLOWED_MODELS=fake/worker-1
export ORCHESTRA_HARNESS="$ROOT/tests/fixtures/fake-harness.sh"
export ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1 ORCHESTRA_KEY_ENV=
export ORCHESTRA_ROUTER_EXT="$ROUTER" FAKE_MODEL=fake/worker-1

out=$( cd "$TMP/repo" && "$W" run R1 --spec spec.md 2>&1 ); rc=$?
[ "$rc" = 0 ] && ok "virtual orchestra/auto is accepted and an allowed physical model passes" \
  || { bad "virtual model with allowed physical model: rc $rc"; sed 's/^/     /' <<<"$out"; }

out=$( cd "$TMP/repo" && FAKE_MODEL=fake/expensive "$W" run R2 --spec spec.md 2>&1 ); rc=$?
[ "$rc" = 3 ] && ok "a disallowed physical model still exits 3 under a virtual model" \
  || { bad "disallowed physical model: rc $rc, want 3"; sed 's/^/     /' <<<"$out"; }

out=$( cd "$TMP/repo" && ORCHESTRA_ROUTER_EXT="$TMP/missing-router.ts" "$W" run R3 --spec spec.md --dry-run 2>&1 ); rc=$?
[ "$rc" = 2 ] && grep -q "ORCHESTRA_ROUTER_EXT not found" <<<"$out" && ok "a missing router extension exits 2" \
  || { bad "missing router extension: rc $rc"; sed 's/^/     /' <<<"$out"; }

# The real pi adapter puts -e <router> next to --no-extensions (a fake pi keeps this offline).
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/pi"; chmod +x "$TMP/bin/pi"
out=$( cd "$TMP/repo" && PATH="$TMP/bin:$PATH" ORCHESTRA_HARNESS=pi "$W" run R4 --spec spec.md --dry-run 2>&1 ); rc=$?
[ "$rc" = 0 ] && grep -qF -- "--no-extensions -e $ROUTER" <<<"$out" && ok "pi argv loads only the router extension with -e" \
  || { bad "pi argv lacks -e $ROUTER next to --no-extensions: rc $rc"; sed 's/^/     /' <<<"$out"; }

if command -v bwrap >/dev/null && bwrap --ro-bind / / true 2>/dev/null; then
  out=$( cd "$TMP/repo" && ORCHESTRA_SANDBOX=bwrap "$W" run R5 --spec spec.md --dry-run 2>&1 ); rc=$?
  [ "$rc" = 0 ] && grep -qF -- "--ro-bind $ROUTER $ROUTER" <<<"$out" && ok "bwrap dry run mounts the router extension read-only" \
    || { bad "bwrap dry run does not mount the router extension: rc $rc"; sed 's/^/     /' <<<"$out"; }
else
  echo "skip: bubblewrap cannot create namespaces here (the bwrap mount check needs it)"
fi

# Doctor: the virtual model is not a preflight failure, and the router file is reported.
out=$( cd "$TMP/repo" && ORCHESTRA_BASE=main ORCHESTRA_GATE=true "$W" doctor 2>&1 ); rc=$?
[ "$rc" = 0 ] && grep -q "virtual model" <<<"$out" && grep -q "router extension: $ROUTER" <<<"$out" \
  && ok "doctor accepts the virtual model and reports the router extension" \
  || { bad "doctor with a router extension: rc $rc"; sed 's/^/     /' <<<"$out"; }

# Scout uses the same virtual-model rule: accepted preflight, physical model still checked after the run.
out=$( cd "$TMP/repo" && ORCHESTRA_HARNESS="$ROOT/tests/fixtures/scout-harness.sh" "$W" scout S1 --spec spec.md 2>&1 ); rc=$?
[ "$rc" = 0 ] && ok "scout accepts the virtual model and an allowed physical model" \
  || { bad "scout with a virtual model: rc $rc"; sed 's/^/     /' <<<"$out"; }

out=$( cd "$TMP/repo" && ORCHESTRA_BASE=main ORCHESTRA_GATE=true ORCHESTRA_ROUTER_EXT="$TMP/missing-router.ts" "$W" doctor 2>&1 ); rc=$?
[ "$rc" = 1 ] && grep -q "FAIL  router extension: $TMP/missing-router.ts not found" <<<"$out" \
  && ok "doctor fails on a missing router extension" \
  || { bad "doctor with a missing router extension: rc $rc"; sed 's/^/     /' <<<"$out"; }

echo "router: $pass passed, $fail failed"
[ "$fail" = 0 ]
