#!/usr/bin/env bash
# candidate: prove records the exact state it passed on (.orchestra/candidate.json), and review/land surface drift
# from it. Offline: no model calls, no network. Drives the real entry points on a throwaway repository and worktree.
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
WORKER="$ROOT/bin/orchestra-worker"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { if grep -qF -- "$2" "$TMP/out"; then ok "$1"; else bad "$1: output lacks '$2'"; sed 's/^/     /' "$TMP/out"; fi; }
line_has() { if grep -qxF -- "$2" "$TMP/out"; then ok "$1"; else bad "$1: output lacks the line '$2'"; sed 's/^/     /' "$TMP/out"; fi; }
line_lacks() { if grep -qxF -- "$2" "$TMP/out"; then bad "$1: output has the line '$2'"; else ok "$1"; fi; }
no_candidate_line() {
  if grep -qE '^candidate' "$TMP/out"; then bad "$1: output has a candidate line"; sed 's/^/     /' "$TMP/out"
  else ok "$1"; fi
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
  cp "$(git -C "$wt" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null || true
  GIT_INDEX_FILE=$idx git -C "$wt" add -A >/dev/null 2>&1
  tree=$(GIT_INDEX_FILE=$idx git -C "$wt" write-tree)
  rc=$?
  rm -f "$idx"
  [ "$rc" = 0 ] && printf '%s' "$tree"
}

# A repository with a bare remote, one task spec, and a task worktree with one changed file and one run log.
REPO="$TMP/repo"; WT="$TMP/repo-worktrees/P1"
REMOTE="$TMP/remote.git"
git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$REPO" 2>/dev/null
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B main origin/main
mkdir -p "$REPO/docs/work/tasks"
cat > "$REPO/docs/work/tasks/P1-greet.md" <<'SPEC'
---
id: P1
title: Add greeting
status: ready
depends: none
delegation: worker
---
## Acceptance
- proof: `test -f greet.txt`

## Out of scope
- nothing
SPEC
git -C "$REPO" add -A
git -C "$REPO" commit -qm spec
git -C "$REPO" push -q origin HEAD:main
git -C "$REPO" worktree add -q -b task/P1 "$WT" origin/main
printf 'hi\n' > "$WT/greet.txt"
mkdir -p "$WT/.orchestra/runs"
: > "$WT/.orchestra/runs/run-1.jsonl"

CAND="$WT/.orchestra/candidate.json"
SPEC_FILE="$WT/docs/work/tasks/P1-greet.md"
BASE_COMMIT=$(git -C "$WT" rev-parse origin/main)

run_prove() {
  ( cd "$REPO" && ORCHESTRA_BASE=origin/main ORCHESTRA_GATE=true "$WORKER" prove P1 ) \
    > "$TMP/out" 2> "$TMP/err"
  local rc=$?
  if [ "$rc" = 0 ]; then ok "prove exits 0"; else bad "prove exits $rc"; sed 's/^/     /' "$TMP/err"; fi
  return "$rc"
}

run_review() {
  ( cd "$REPO" && ORCHESTRA_BASE=origin/main ORCHESTRA_GATE=true "$WORKER" review P1 ) \
    > "$TMP/out" 2> "$TMP/err"
  local rc=$?
  if [ "$rc" = 0 ]; then ok "review exits 0"; else bad "review exits $rc"; sed 's/^/     /' "$TMP/err"; fi
  return "$rc"
}

run_review_json() {
  ( cd "$REPO" && ORCHESTRA_BASE=origin/main ORCHESTRA_GATE=true "$WORKER" review P1 --json ) \
    > "$TMP/json" 2> "$TMP/err"
  local rc=$?
  if [ "$rc" = 0 ]; then ok "review --json exits 0"; else bad "review --json exits $rc"; sed 's/^/     /' "$TMP/err"; fi
  return "$rc"
}

# 1. A passing prove writes the candidate: its tree is the worktree's tree, and the record is valid JSON.
run_prove || true
TREE=$(current_tree "$WT")
SPEC_TREE=$(git -C "$WT" hash-object "$SPEC_FILE")
if [ -f "$CAND" ]; then ok "prove writes .orchestra/candidate.json"; else bad "prove wrote no candidate.json"; fi
if python3 -I - "$CAND" "$TREE" "$BASE_COMMIT" "$SPEC_FILE" "$SPEC_TREE" <<'PY'
import json, re, sys
path, tree, base_commit, spec, spec_tree = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    d = json.load(f)
assert d["task"] == "P1"
assert d["tree"] == tree, (d["tree"], tree)
assert d["run"] == 1, d["run"]
assert d["base"] == "origin/main", d["base"]
assert d["base_commit"] == base_commit, d["base_commit"]
assert d["spec"] == spec, d["spec"]
assert d["spec_tree"] == spec_tree, d["spec_tree"]
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["at"]), d["at"]
PY
then ok "the candidate records task, run, base, base_commit, tree, spec, spec_tree, at"; else
  bad "the candidate record is wrong or not valid JSON"; sed 's/^/     /' "$CAND" 2>/dev/null; fi

# 6. Writing the candidate does not invalidate the proof it records: it lives under the excluded .orchestra/.
run_prove || true
has "the candidate does not invalidate the next prove" "(proven)"

# 2. Without a candidate, review is exactly as before: no line, and null in JSON.
mv "$CAND" "$TMP/candidate.json.bak"
run_review || true
no_candidate_line "review without a candidate prints no candidate line"
run_review_json || true
json_check "review --json without a candidate reports null" 'd["candidate"] is None'
mv "$TMP/candidate.json.bak" "$CAND"

# 3. A candidate and an unchanged tree: the candidate line, no drift, drift false.
run_review || true
line_has "review prints the candidate line" "candidate: run 1, base origin/main, tree ${TREE:0:12}"
line_lacks "an unchanged tree has no drift line" "candidate drift: worktree differs from the candidate tree"
run_review_json || true
json_check "review --json reports the candidate" 'd["candidate"]["tree"] == "'"$TREE"'" and d["candidate"]["run"] == 1 and d["candidate"]["task"] == "P1"'
json_check "review --json reports no drift" 'd["candidate"]["drift"] is False and d["candidate"]["drift_stat"] == ""'

# 4. A changed tree: the drift line, the stat, drift true and a non-empty drift_stat.
printf 'hi there\n' > "$WT/greet.txt"
run_review || true
line_has "a changed tree prints the candidate line" "candidate: run 1, base origin/main, tree ${TREE:0:12}"
line_has "a changed tree prints the drift line" "candidate drift: worktree differs from the candidate tree"
has "the drift stat is shown, indented like land's changes stat" "   greet.txt | 2 +-"
run_review_json || true
json_check "review --json reports drift" 'd["candidate"]["drift"] is True'
json_check "review --json carries the drift stat" 'd["candidate"]["drift_stat"] != "" and "greet.txt" in d["candidate"]["drift_stat"]'

# 5. Land with a changed tree: the notice, still lands, and re-proves the tree it publishes.
( cd "$REPO" && ORCHESTRA_BASE=origin/main ORCHESTRA_GATE=true "$WORKER" land P1 ) \
  > "$TMP/out" 2> "$TMP/err"
rc=$?
if [ "$rc" = 0 ]; then ok "land exits 0 with a drift notice"; else
  bad "land exits $rc"; sed 's/^/     /' "$TMP/err"; sed 's/^/     /' "$TMP/out"; fi
has "land prints the drift notice" "candidate drift: publishing a tree that differs from the candidate"
LANDED_TREE=$(git -C "$REMOTE" rev-parse "main^{tree}")
if [ -n "$LANDED_TREE" ] && [ "$LANDED_TREE" != "$TREE" ]; then
  ok "the landed commit re-proved a tree that differs from the old candidate tree"
else bad "the landed tree equals the old candidate tree ($LANDED_TREE)"; fi
if python3 -I - "$CAND" "$LANDED_TREE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
assert d["tree"] == sys.argv[2], (d["tree"], sys.argv[2])
PY
then ok "land left a fresh candidate for the tree it published"; else
  bad "candidate after land does not match the landed tree"; sed 's/^/     /' "$CAND"; fi

printf 'candidate: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
