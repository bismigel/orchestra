#!/usr/bin/env bash
# examples/pi/orchestra.ts: offline tests for the direct-edit nudge, through the extension's real tool_result hook.
# No pi runtime and no model: typebox is stubbed, the extension is imported by node from a temporary copy.
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/node_modules/typebox"
printf '{"name":"typebox","type":"module","main":"index.js"}\n' > "$TMP/node_modules/typebox/package.json"
cat > "$TMP/node_modules/typebox/index.js" <<'JS'
const any = (...a) => ({ stub: a });
export const Type = new Proxy({}, { get: () => any });
JS
cp "$ROOT/examples/pi/orchestra.ts" "$TMP/orchestra.mjs"
# A repository that uses orchestra, and one that does not.
mkdir -p "$TMP/repo/.git" "$TMP/repo/.orchestra" "$TMP/repo/docs/work/tasks" "$TMP/repo/src" "$TMP/plain/.git"
: > "$TMP/repo/.orchestra/config.env"
export EXT="$TMP/orchestra.mjs" REPO="$TMP/repo" PLAIN="$TMP/plain"
out=$(cd "$TMP" && node --input-type=module - <<'JS' 2>&1
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const m = await import(pathToFileURL(process.env.EXT).href);
const { REPO, PLAIN } = process.env;
let pass = 0, fail = 0;
const t = async (name, fn) => {
  try { await fn(); pass++; console.log("ok   " + name); } catch (e) { fail++; console.log("FAIL " + name + ": " + (e && e.message)); }
};
const eq = (a, b, what) => assert.deepEqual(a, b, `${what}: got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`);

// Load the extension against a fake pi and drive its tool_result hook.
function load(env) {
  const saved = process.env.ORCHESTRA_DIRECT_EDIT_WARN;
  if (env == null) delete process.env.ORCHESTRA_DIRECT_EDIT_WARN; else process.env.ORCHESTRA_DIRECT_EDIT_WARN = env;
  const handlers = {}; const tools = [];
  m.default({ on: (ev, fn) => { handlers[ev] = fn; }, registerTool: (d) => tools.push(d.name), registerCommand: () => {} });
  if (saved == null) delete process.env.ORCHESTRA_DIRECT_EDIT_WARN; else process.env.ORCHESTRA_DIRECT_EDIT_WARN = saved;
  const call = (toolName, input, cwd = REPO, isError = false) =>
    handlers.tool_result({ toolName, input, isError, content: [{ type: "text", text: "done" }] }, { cwd });
  return { handlers, tools, call };
}
const noted = (r) => !!r && r.content.some((c) => /\[orchestra\]/.test(c.text));

await t("no reminder below the threshold, one at it, and the original content is kept", () => {
  const x = load();
  eq(noted(x.call("edit", { path: "src/a.go" })), false, "1st");
  eq(noted(x.call("edit", { path: "src/b.go" })), false, "2nd");
  const r = x.call("write", { path: REPO + "/src/c.go" });
  eq(noted(r), true, "3rd fires");
  eq(r.content[0].text, "done", "tool output first");
  eq(noted(x.call("edit", { path: "src/d.go" })), false, "4th quiet until the next multiple");
});
await t("the same file edited again does not count twice", () => {
  const x = load();
  for (let i = 0; i < 5; i++) eq(noted(x.call("edit", { path: "src/a.go" })), false, "edit " + i);
});
await t("specs, docs, Markdown and .orchestra are ignored", () => {
  const x = load("1");
  for (const p of ["docs/work/tasks/T9.md", "docs/design.html", "README.md", ".orchestra/feedback.txt", "/elsewhere/x.go"]) {
    eq(noted(x.call("edit", { path: p })), false, p);
  }
  eq(noted(x.call("edit", { path: "src/x.go" })), true, "a source file still counts");
});
await t("failed edits and other tools are ignored", () => {
  const x = load("1");
  eq(noted(x.call("edit", { path: "src/a.go" }, REPO, true)), false, "error");
  eq(noted(x.call("read", { path: "src/a.go" })), false, "read");
  eq(noted(x.call("bash", { command: "sed -i s/a/b/ src/a.go" })), false, "bash");
});
await t("orchestra_run resets the count", () => {
  const x = load("2");
  x.call("edit", { path: "src/a.go" });
  x.call("orchestra_run", { task: "T1" });
  eq(noted(x.call("edit", { path: "src/b.go" })), false, "count restarted");
  eq(noted(x.call("edit", { path: "src/c.go" })), true, "fires again at 2");
});
await t("decide mark ... split orchestrator silences the session", () => {
  const x = load("1");
  x.call("bash", { command: "orchestra-worker decide mark T7 split orchestrator" });
  eq(noted(x.call("edit", { path: "src/a.go" })), false, "quiet");
});
await t("ORCHESTRA_DIRECT_EDIT_WARN=0 turns it off; repositories without orchestra are left alone", () => {
  const off = load("0");
  for (const p of ["src/a.go", "src/b.go", "src/c.go"]) eq(noted(off.call("edit", { path: p })), false, "off " + p);
  const plain = load("1");
  eq(noted(plain.call("edit", { path: "src/a.go" }, PLAIN)), false, "no orchestra here");
});
await t("the orchestra tools are still registered", () => {
  const x = load();
  eq(["orchestra_scout", "orchestra_run", "orchestra_review", "orchestra_prove", "orchestra_land"].every((n) => x.tools.includes(n)), true, "tools");
});
console.log(`pi-extension: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
JS
); rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ]
