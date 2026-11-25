#!/usr/bin/env bash
# artifact: the self-contained HTML review artifact for a run and a scout, the one local folder with index.html,
# the --json summary, and the graceful local fallback when a remote Artifact Server cannot be reached.
# Offline: no model calls, no network (the remote case points at an unreachable localhost port).
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
ARTIFACT="$ROOT/lib/artifact.py"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
file_has() {
  local file=$1 needle=$2 name=$3
  if grep -qF -- "$needle" "$file"; then ok "$name"; else
    bad "$name: '$file' lacks '$needle'"; sed 's/^/     /' "$file" | head -20
  fi
}
file_lacks() {
  local file=$1 needle=$2 name=$3
  if grep -qF -- "$needle" "$file"; then bad "$name: '$file' has '$needle'"; else ok "$name"; fi
}
exists() { [ -e "$1" ] && ok "$2" || bad "$2: missing $1"; }

# A repository on main and a task worktree with a report, proofs, a spec, state.md, a diff and an untracked file.
REPO="$TMP/demo"
WT="$TMP/demo-worktrees/A1"
OUT="$TMP/artifacts"
mkdir -p "$REPO/src"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf 'print(0)\n' > "$REPO/src/a.py"
printf 'hello\n' > "$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init
git -C "$REPO" worktree add -q -b A1 "$WT" main

printf 'print(1)\n' > "$WT/src/a.py"
printf 'new untracked line\n' > "$WT/src/untracked.txt"
mkdir -p "$WT/.orchestra/runs"
cat > "$WT/.orchestra/spec.md" <<'SPEC'
---
id: A1
title: Artifact fixture
status: ready
depends: none
delegation: worker
---
## Owns
- `src/`

## Acceptance
- proof: `true`

## Out of scope
- nothing
SPEC
cat > "$WT/.orchestra/report.json" <<'REPORT'
{
  "task": "A1",
  "status": "done",
  "summary": "rendered the fixture <script>alert(1)</script>",
  "files_changed": ["src/a.py", "src/untracked.txt"],
  "checks": [{"command": "tests/run.sh", "result": "pass"}],
  "open_questions": ["Is the name fixed <script>alert(2)</script>?"],
  "risk_notes": ["Risk note with <script>alert(3)</script> markup"],
  "assumptions": ["Used the existing helper."],
  "out_of_scope_needed": ["docs need updating"],
  "rendered_diff": ["--- a/rendered.txt\n+++ b/rendered.txt\n+rendered report entry"]
}
REPORT
printf '{"exit":0,"secs":65}\n' > "$WT/.orchestra/runs/run-1.result.json"
printf '{"responses":23,"cost":0.012}\n' > "$WT/.orchestra/runs/run-1.usage.json"
: > "$WT/.orchestra/runs/run-1.jsonl"
printf '{"check":"proof-one.sh","exit":0,"secs":1,"tree":"1111111111111111111111111111111111111111"}\n' \
  > "$WT/.orchestra/proofs.jsonl"
printf '{"check":"proof-two.sh","exit":1,"secs":2,"tree":"2222222222222222222222222222222222222222"}\n' \
  >> "$WT/.orchestra/proofs.jsonl"
printf '## Plan\n\nworktree state line\n' > "$WT/.orchestra/state.md"
printf 'rendered from a file\n+added rendered line\n' > "$TMP/rendered.txt"

# 1. A run artifact: human output, the file in the out-dir, and every escaped section.
python3 -I "$ARTIFACT" --repo "$REPO" --task A1 --base main --worktree "$WT" \
  --rendered-diff-file "$TMP/rendered.txt" --out-dir "$OUT" --local > "$TMP/out" 2> "$TMP/err"
rc=$?
[ "$rc" = 0 ] && ok "run artifact exits 0" || { bad "run artifact exits $rc"; sed 's/^/     /' "$TMP/err"; }
A1_HTML=$(sed -n 's/^local artifact: //p' "$TMP/out" | tail -1)
A1_INDEX=$(sed -n 's/^index: //p' "$TMP/out" | tail -1)
file_has "$TMP/out" "local artifact: " "human output names the local artifact"
file_has "$TMP/out" "index: " "human output names the index"
file_has "$TMP/out" "file://" "human output prints the file:// path"
exists "$A1_HTML" "the run artifact exists in the out-dir"
[ "$A1_INDEX" = "$OUT/index.html" ] && ok "the index is the out-dir's index.html" || bad "index is $A1_INDEX"

file_has "$A1_HTML" "BLOCKING questions (1)" "overview shows the blocking count"
file_has "$A1_HTML" "Is the name fixed" "overview shows the blocking question"
file_has "$A1_HTML" "Risk note with" "overview shows risk_notes"
file_has "$A1_HTML" "Used the existing helper." "overview shows assumptions"
file_has "$A1_HTML" "docs need updating" "overview shows out-of-scope needs"
file_has "$A1_HTML" "proof-one.sh" "proofs table shows the passing check"
file_has "$A1_HTML" "proof-two.sh" "proofs table shows the failing check"
file_has "$A1_HTML" 'class="fail"' "proofs table marks a failure"
file_has "$A1_HTML" "Artifact fixture" "overview renders the spec"
file_has "$A1_HTML" "@@" "source diff contains a hunk header"
file_has "$A1_HTML" "+print(1)" "source diff contains the changed line"
file_has "$A1_HTML" "+new untracked line" "source diff includes untracked files"
file_has "$A1_HTML" "rendered from a file" "rendered diff file content appears"
file_has "$A1_HTML" "rendered report entry" "report rendered_diff entries appear"
file_has "$A1_HTML" "worktree state line" "state.md from the worktree appears"

# 2. Escaping: the fixture's <script> strings appear escaped and can never run.
file_has "$A1_HTML" "&lt;script&gt;alert(3)&lt;/script&gt;" "risk notes are HTML-escaped"
file_has "$A1_HTML" "&lt;script&gt;alert(2)&lt;/script&gt;" "questions are HTML-escaped"
file_has "$A1_HTML" "&lt;script&gt;alert(1)&lt;/script&gt;" "summary is HTML-escaped"
file_lacks "$A1_HTML" "<script>alert(3)" "no raw script tag from risk notes"
file_lacks "$A1_HTML" "<script>alert(2)" "no raw script tag from questions"
file_lacks "$A1_HTML" "<script>alert(1)" "no raw script tag from the summary"

# 3. A scout artifact with state.md, drift, undecided and files_to_change; --json is the only stdout.
SCOUT="$TMP/demo-worktrees/.scout/A2"
mkdir -p "$SCOUT"
cat > "$SCOUT/state.md" <<'STATE'
# State

- step one
- step two <b>not bold</b>
STATE
cat > "$SCOUT/scout.json" <<'SCOUTJSON'
{
  "task": "A2",
  "drift": "The spec drifted from the code <script>alert(4)</script>",
  "undecided": ["Which name should it use?"],
  "files_to_change": [
    {"path": "src/b.py", "what": "the new handler", "in_spec": false}
  ]
}
SCOUTJSON
python3 -I "$ARTIFACT" --repo "$REPO" --task A2 --base main --scout-dir "$SCOUT" \
  --out-dir "$OUT" --local --json > "$TMP/json" 2> "$TMP/json.err"
rc=$?
[ "$rc" = 0 ] && ok "scout artifact exits 0" || { bad "scout artifact exits $rc"; sed 's/^/     /' "$TMP/json.err"; }
python3 -I - "$TMP/json" "$OUT" "$REPO" <<'PY'
import json, os, sys
path, out, repo = sys.argv[1:]
d = json.load(open(path))
assert set(d) == {"mode", "path", "url", "index", "task", "repo"}, set(d)
assert d["mode"] == "local", d
assert d["task"] == "A2", d
assert d["repo"] == os.path.basename(repo), d
assert d["index"] == os.path.join(out, "index.html"), d
assert os.path.dirname(d["path"]) == out, d
assert os.path.isfile(d["path"]), d
assert os.path.isfile(d["index"]), d
assert d["url"] is None, d
PY
[ "$?" = 0 ] && ok "--json emits a valid local summary" || bad "--json summary is invalid"

A2_HTML=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["path"])' "$TMP/json")
A1_FILE=$(basename "$A1_HTML")
A2_FILE=$(basename "$A2_HTML")
file_has "$A2_HTML" "step two" "state.md content appears in the scout artifact"
file_has "$A2_HTML" "The spec drifted from the code" "scout drift appears"
file_has "$A2_HTML" "Which name should it use?" "scout undecided appears"
file_has "$A2_HTML" "src/b.py" "scout files_to_change appears"
file_has "$A2_HTML" "&lt;script&gt;alert(4)&lt;/script&gt;" "scout text is HTML-escaped"

# 4. One flat out-dir, both artifacts (and latest copies) there, index newest first, manifest has both.
exists "$OUT/$A1_FILE" "the run artifact is flat in the out-dir"
exists "$OUT/$A2_FILE" "the scout artifact is flat in the out-dir"
[ -z "$(find "$OUT" -mindepth 1 -maxdepth 1 -type d -print -quit)" ] && ok "the out-dir has no subdirectories" \
  || bad "the out-dir has subdirectories"
exists "$OUT/demo-A1-latest.html" "the run artifact keeps an A1 latest copy"
exists "$OUT/demo-A2-latest.html" "the scout artifact keeps an A2 latest copy"
exists "$OUT/index.html" "index.html exists"
exists "$OUT/manifest.json" "manifest.json exists"
python3 -I - "$OUT/index.html" "$A2_FILE" "$A1_FILE" "$OUT/manifest.json" <<'PY'
import json, sys
index, newest, older, manifest = sys.argv[1:]
text = open(index, encoding="utf-8").read()
assert newest in text and older in text, (newest, older)
assert text.find(newest) < text.find(older), "index is not newest first"
data = json.load(open(manifest, encoding="utf-8"))
assert isinstance(data.get("artifacts"), list) and len(data["artifacts"]) == 2, data
assert data["artifacts"][0]["file"] == newest, data["artifacts"]
PY
[ "$?" = 0 ] && ok "index lists both artifacts newest first and the manifest has both" \
  || bad "index order or manifest is wrong"

# 5. A remote Artifact Server that cannot be reached falls back to local, keeps the artifact, and never prints the token.
( export ARTIFACT_SERVER_ORIGIN="http://127.0.0.1:1" ARTIFACT_SERVER_AGENT_TOKEN="dummy-token-never-print"
  unset ORCHESTRA_ARTIFACT_SERVER_ORIGIN ORCHESTRA_ARTIFACT_TOKEN_CMD
  python3 -I "$ARTIFACT" --repo "$REPO" --task A1 --base main --worktree "$WT" \
    --out-dir "$TMP/fallback" --json ) > "$TMP/fb.json" 2> "$TMP/fb.err"
rc=$?
[ "$rc" = 0 ] && ok "unreachable remote still exits 0" || { bad "fallback exits $rc"; sed 's/^/     /' "$TMP/fb.err"; }
python3 -I - "$TMP/fb.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["mode"] == "local", d
assert d["url"] is None, d
assert os.path.isfile(d["path"]), d
PY
[ "$?" = 0 ] && ok "unreachable remote falls back to a local artifact" || bad "fallback JSON is not local"
file_has "$TMP/fb.err" "remote publish unavailable" "fallback prints one concise warning"
file_has "$TMP/fb.err" "saved locally: " "fallback names the saved local path"
if grep -qF "dummy-token-never-print" "$TMP/fb.json" "$TMP/fb.err"; then
  bad "the dummy token was printed"
else
  ok "the dummy token is never printed"
fi

printf 'artifact: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
