#!/usr/bin/env bash
# review: the one-screen digest of a finished run, and the scout view. Offline: no model calls, no network.
# Drives the real entry point on a throwaway repository and task worktree; checks that the real index is untouched.
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
WORKER="$ROOT/bin/orchestra-worker"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { if grep -qF -- "$2" "$TMP/out"; then ok "$1"; else bad "$1: output lacks '$2'"; sed 's/^/     /' "$TMP/out"; fi; }
line_has() { if grep -qxF -- "$2" "$TMP/out"; then ok "$1"; else bad "$1: output lacks the line '$2'"; sed 's/^/     /' "$TMP/out"; fi; }
line_lacks() { if grep -qxF -- "$2" "$TMP/out"; then bad "$1: output has the line '$2'"; else ok "$1"; fi; }

# run_review: real entry point, with no config and a fixed base/gate. Output in $TMP/out, errors in $TMP/err.
run_review() {
  ( cd "$REPO" && ORCHESTRA_BASE=main ORCHESTRA_GATE='true' "$WORKER" review R1 ) \
    > "$TMP/out" 2> "$TMP/err"
  local rc=$?
  if [ "$rc" = 0 ]; then ok "review exits 0"; else bad "review exits $rc"; sed 's/^/     /' "$TMP/err"; fi
  return "$rc"
}

# run_review_json: same as run_review, with --json. The object lands in $TMP/json.
run_review_json() {
  ( cd "$REPO" && ORCHESTRA_BASE=main ORCHESTRA_GATE='true' "$WORKER" review R1 --json ) \
    > "$TMP/json" 2> "$TMP/err"
  local rc=$?
  if [ "$rc" = 0 ]; then ok "review --json exits 0"; else bad "review --json exits $rc"; sed 's/^/     /' "$TMP/err"; fi
  return "$rc"
}

# json_check: parse $TMP/json and assert a Python expression over `d`.
json_check() {
  if python3 -I - "$TMP/json" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert eval(sys.argv[2])
PY
  then ok "$1"; else bad "$1: JSON assertion '$2' failed"; sed 's/^/     /' "$TMP/json"; fi
}

# current_tree: the same tree hash work_tree uses (all tracked and untracked files, real index untouched).
current_tree() {
  local wt=$1 idx tree rc
  idx=$(mktemp)
  cp -p "$(git -C "$wt" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null || true
  GIT_INDEX_FILE=$idx git -C "$wt" add -A >/dev/null 2>&1
  tree=$(GIT_INDEX_FILE=$idx git -C "$wt" write-tree)
  rc=$?
  rm -f "$idx"
  [ "$rc" = 0 ] && printf '%s' "$tree"
}

# A repository with one task spec, and a task worktree with changes in and outside the spec's paths.
REPO="$TMP/demo"
mkdir -p "$REPO/src" "$REPO/docs/work/tasks"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf 'print(0)\n' > "$REPO/src/a.py"
printf 'hello\n' > "$REPO/README.md"
cat > "$REPO/docs/work/tasks/R1-x.md" <<'SPEC'
---
id: R1
title: Review fixture
status: ready
depends: none
delegation: worker
---
## Owns
- `src/`

## Touches
- `README.md`: one line

## Acceptance
- proof: `test -f greet.txt`

## Out of scope
- nothing
SPEC
git -C "$REPO" add -A
git -C "$REPO" commit -qm init
git -C "$REPO" worktree add -q -b R1 "$TMP/demo-worktrees/R1" main
WT="$TMP/demo-worktrees/R1"

printf 'print(1)\n' > "$WT/src/a.py"
printf 'hello there\n' > "$WT/README.md"
mkdir -p "$WT/other" "$WT/.orchestra/runs"
printf 'other\n' > "$WT/other/x.py"
printf 'package view\n' > "$WT/view_templ.go"
cat > "$WT/.orchestra/report.json" <<'REPORT'
{
  "task": "R1",
  "status": "done",
  "summary": "implemented the greeting",
  "files_changed": ["src/a.py"],
  "checks": [
    {"command": "tests/run.sh", "result": "pass"},
    {"command": "go test ./x", "result": "fail"}
  ],
  "open_questions": ["Is the greeting name fixed?", "Should the greeting be localised?"],
  "assumptions": ["Used the existing greeting helper."],
  "out_of_scope_needed": ["docs need updating"],
  "risk_notes": ["Touches a shared cluster policy; try it on a scratch namespace.", "Rollback: revert the manifest."],
  "rendered_diff": ["- replicas: 1", "+ replicas: 2"],
  "acceptance": [
    {"item": "greeting prints", "met": true},
    {"item": "name flag", "met": false}
  ]
}
REPORT
printf '{"exit":0,"secs":65}\n' > "$WT/.orchestra/runs/run-1.result.json"
printf '{"responses":23,"cost":0.012}\n' > "$WT/.orchestra/runs/run-1.usage.json"
: > "$WT/.orchestra/runs/run-1.jsonl"

run_review || true

# 1. OUTSIDE PATHS covers Owns/Touches, ignores generated files, and names only the real stray.
line_has "outside path lists other/x.py" "  other/x.py"
line_lacks "outside path does not list src/a.py" "  src/a.py"
line_lacks "outside path does not list README.md" "  README.md"
line_lacks "outside path does not list a generated file" "  view_templ.go"
has "outside path count" "OUTSIDE PATHS (1): changed files the spec's Owns/Touches do not cover"

# 2. The report's blocking questions and assumptions come first, with their texts.
has "blocking count" "BLOCKING (2)"
line_has "first blocking question" "  1. Is the greeting name fixed?"
line_has "second blocking question" "  2. Should the greeting be localised?"
has "assumed count" "assumed (1)"
line_has "assumption text" "  1. Used the existing greeting helper."
has "outside scope needed" "outside scope needed (1)"
line_has "outside scope text" "  - docs need updating"
has "risk notes count" "RISK NOTES (2)"
line_has "first risk note" "  1. Touches a shared cluster policy; try it on a scratch namespace."
line_has "second risk note" "  2. Rollback: revert the manifest."
has "rendered diff section" "rendered diff"
line_has "rendered diff line" "  + replicas: 2"

# 1b. The lessons reminder sits directly before the next line and counts every spec gap.
line_has "lessons reminder counts the spec gaps" "lessons   5 spec gap(s): orchestra-worker lessons R1"

# 2b. The --json object carries the same digest for editor widgets.
run_review_json || true
json_check "--json parses" 'd["task"] == "R1"'
json_check "--json has every key" 'set(d) == {"task", "run", "candidate", "report_valid", "status", "summary", "blocking", "assumed", "outside_scope_needed", "risk_notes", "rendered_diff", "paths", "spec_gaps", "worker_checks", "acceptance", "proofs", "diff"} and set(d["run"]) == {"n", "exit", "meaning", "secs", "responses", "cost", "task_total", "runs"} and set(d["paths"]) == {"checked", "outside"} and set(d["proofs"]) == {"tree", "checks", "manual"} and set(d["diff"]) == {"files", "added", "removed", "generated", "list"}'
json_check "--json blocking texts" 'd["blocking"] == ["Is the greeting name fixed?", "Should the greeting be localised?"]'
json_check "--json assumption text" 'd["assumed"] == ["Used the existing greeting helper."]'
json_check "--json outside path" 'd["paths"]["outside"] == ["other/x.py"]'
json_check "--json counts the spec gaps" 'd["spec_gaps"] == 5'
json_check "--json run exit and secs" 'd["run"]["exit"] == 0 and d["run"]["secs"] == 65'
json_check "--json marks the generated file" 'any(f["path"] == "view_templ.go" and f["generated"] for f in d["diff"]["list"])'
json_check "--json carries risk notes" 'd["risk_notes"] == ["Touches a shared cluster policy; try it on a scratch namespace.", "Rollback: revert the manifest."]'
json_check "--json carries the rendered diff" 'd["rendered_diff"] == ["- replicas: 1", "+ replicas: 2"]'

# 2c. Task sections may use a top-level # heading, and an unbackticked proof: line is a warning.
cat > "$TMP/hash-headings.md" <<'SPEC'
---
id: R1
title: Review fixture
status: ready
depends: none
delegation: worker
---
# Touches
- `README.md`: one line

# Acceptance
L8 proof: command must be in backticks

# Out of scope
- nothing
SPEC
python3 -I - "$TMP/hash-headings.md" "$ROOT/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
import task_lint
_fm, sections = task_lint.parse(sys.argv[1])
assert "touches" in sections, sections
assert "acceptance" in sections, sections
line = [l for l in sections["acceptance"].splitlines() if "proof:" in l][0]
assert task_lint.PROOF_ANY.search(line) and not task_lint.PROOF.search(line), line
PY
if [ $? = 0 ]; then ok "# headings are sections and an unbackticked proof: line is caught"; else
  bad "# heading / proof: warning fixture failed"; fi

# 3. Header: run number, exit meaning, duration, responses and cost; a missing result file says exit ?.
has "header run and exit" "run 1 exit 0 (ok)"
has "header duration" "1m05s"
has "header responses" "23 responses"
has "header run cost" '$0.0120'
has "header task total" "task total: \$0.0120, 1 run)"
mv "$WT/.orchestra/runs/run-1.result.json" "$TMP/run-1.result.json"
run_review || true
has "missing result shows exit ?" "run 1 exit ?"
run_review_json || true
json_check "--json unknown exit is null" 'd["run"]["exit"] is None and d["run"]["meaning"] == ""'
mv "$TMP/run-1.result.json" "$WT/.orchestra/runs/run-1.result.json"

# 4. Proofs are bound to the exact tree: a current row passes, an old row is not counted, no row is not run.
TREE=$(current_tree "$WT")
printf '{"check":"true","exit":0,"secs":1,"tree":"%s"}\n' "$TREE" > "$WT/.orchestra/proofs.jsonl"
printf '{"check":"test -f greet.txt","exit":0,"secs":1,"tree":"0000000000000000000000000000000000000000"}\n' \
  >> "$WT/.orchestra/proofs.jsonl"
run_review || true
line_has "a proof on the current tree passes" "  pass     true"
line_has "a proof with no row is not run" "  not run  test -f greet.txt"
has "proofs show the tree" "(tree ${TREE:0:12})"

# 5. The diff marks generated files and ranks the changed files.
has "diff marks the generated file" "view_templ.go (generated)"
has "diff counts files" "files ·"

# 6. A spec without Owns/Touches is not checked.
cp "$WT/docs/work/tasks/R1-x.md" "$TMP/R1-spec.md"
cat > "$WT/docs/work/tasks/R1-x.md" <<'NOSPEC'
---
id: R1
title: Review fixture
status: ready
depends: none
delegation: worker
---
## Acceptance
- `true`

## Out of scope
- nothing
NOSPEC
run_review || true
has "a spec without Owns/Touches is not checked" "paths     not checked (no Owns/Touches in the spec)"
run_review_json || true
json_check "--json paths not checked without Owns/Touches" 'd["paths"]["checked"] is False'
cp "$TMP/R1-spec.md" "$WT/docs/work/tasks/R1-x.md"

# 7. Review is read-only for the worktree's real index.
if [ -z "$(git -C "$WT" diff --cached --name-only)" ]; then ok "the real index is unchanged"; else
  bad "review changed the real index: $(git -C "$WT" diff --cached --name-only | tr '\n' ' ')"
fi

# 8. The scout view: not-found mappings, broken commands with fixes, and the paste block; a wrong task exits 1.
python3 -I "$ROOT/lib/scout_view.py" "$ROOT/tests/fixtures/scout.json" S1 "$TMP/no-usage.json" \
  > "$TMP/out" 2> "$TMP/err"
rc=$?
if [ "$rc" = 0 ]; then ok "scout view exits 0"; else bad "scout view exits $rc"; sed 's/^/     /' "$TMP/err"; fi
has "scout header" "scout S1 · 0 responses · \$0.0000"
has "scout named count" "named      2 checked · 1 not where the spec says"
line_has "scout not-found mapping" "  marketing.go → internal/web/legal.go:40 (renamed)"
has "scout broken command" "commands   1 does not run"
line_has "scout corrected command" '  `go test ./services/extractor/` → `cd services/extractor && go test ./...`'
has "scout size with split" "size       ~8 files, ~300 lines · split:"
has "scout paste block" "add to the spec (Touches):"
line_has "scout paste file" '- `internal/web/legal.go`: the handler moved here'
line_has "scout paste test" '- `internal/web/notice_test.go`: asserts the rendered notice text changes (TestNotice)'
rc=0
python3 -I "$ROOT/lib/scout_view.py" "$ROOT/tests/fixtures/scout.json" S9 "$TMP/no-usage.json" \
  > "$TMP/out" 2> "$TMP/err" || rc=$?
if [ "$rc" = 1 ]; then ok "scout view rejects a wrong task id"; else bad "wrong task id exits $rc, want 1"; fi
if grep -qF 'invalid scout report' "$TMP/err"; then ok "scout view explains an invalid report"; else
  bad "scout view error lacks 'invalid scout report'"; sed 's/^/     /' "$TMP/err"
fi

printf 'review: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
