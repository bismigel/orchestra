#!/usr/bin/env bash
# lessons: draft lessons.md lines from what a run's review shows the spec missed. Offline: no model calls,
# no network. Also covers the lint warning for a task without a `proof:` line, and `lint --strict`.
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
WORKER="$ROOT/bin/orchestra-worker"
TASK_BIN="$ROOT/bin/orchestra-task"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { if grep -qF -- "$2" "$TMP/out"; then ok "$1"; else bad "$1: output lacks '$2'"; sed 's/^/     /' "$TMP/out"; fi; }
hasnt() { if grep -qF -- "$2" "$TMP/out"; then bad "$1: output contains '$2'"; else ok "$1"; fi; }
line_has() { if grep -qxF -- "$2" "$TMP/out"; then ok "$1"; else bad "$1: output lacks the line '$2'"; sed 's/^/     /' "$TMP/out"; fi; }

TODAY=$(date -u +%F)

# lessons_from: run lib/lessons.py on a JSON file. Output in $TMP/out, errors in $TMP/err.
lessons_from() {
  python3 -I "$ROOT/lib/lessons.py" --task T41 < "$1" > "$TMP/out" 2> "$TMP/err"
}

# 1. Three gaps: blocking, then an outside path, then an assumption, each with the task and today's date.
cat > "$TMP/gaps.json" <<'JSON'
{
  "task": "T41",
  "run": {"n": 2, "exit": 0},
  "blocking": ["The greeting name is fixed"],
  "assumed": ["Used the existing greeting helper"],
  "outside_scope_needed": [],
  "paths": {"checked": true, "outside": ["src/other.py"]}
}
JSON
if lessons_from "$TMP/gaps.json"; then ok "lessons exits 0 on spec gaps"; else bad "lessons exited $?"; fi
has "draft header names the task and run" "# lessons draft for T41, run 2: keep the lines that would change a future spec, write the rule, then append"
line_has "blocking gap line" "- $TODAY T41: the spec left this open: The greeting name is fixed. Rule: <write the rule>"
line_has "outside path line" "- $TODAY T41: the worker had to change \`src/other.py\`, outside Owns/Touches. Rule: <write the rule>"
line_has "assumed line" "- $TODAY T41: the worker assumed: Used the existing greeting helper. Rule (only if it should have been decided): <write the rule>"
b=$(grep -nF 'the spec left this open' "$TMP/out" | cut -d: -f1)
p=$(grep -nF 'outside Owns/Touches' "$TMP/out" | cut -d: -f1)
a=$(grep -nF 'the worker assumed' "$TMP/out" | cut -d: -f1)
if [ -n "$b" ] && [ -n "$p" ] && [ -n "$a" ] && [ "$b" -lt "$p" ] && [ "$p" -lt "$a" ]; then
  ok "gaps are ordered blocking, outside paths, assumed"
else
  bad "gaps are out of order (blocking=$b outside=$p assumed=$a)"
fi

# 2. No gaps: one nothing-to-record line and no draft header.
cat > "$TMP/empty.json" <<'JSON'
{
  "task": "T41",
  "run": null,
  "blocking": [],
  "assumed": [],
  "outside_scope_needed": [],
  "paths": {"checked": true, "outside": []}
}
JSON
if lessons_from "$TMP/empty.json"; then ok "lessons exits 0 with no gaps"; else bad "lessons exited $? with no gaps"; fi
line_has "nothing to record" "no spec gaps in T41's last run: nothing to record"
hasnt "no draft header without gaps" "# lessons draft"
if [ "$(wc -l < "$TMP/out")" = 1 ]; then ok "nothing-to-record output is one line"; else
  bad "nothing-to-record output has $(wc -l < "$TMP/out") lines"
fi

# 3. A 300-character item is collapsed to one line and cut to 200 characters with an ellipsis.
python3 -I - > "$TMP/long.json" <<'PY'
import json
print(json.dumps({
    "task": "T41",
    "run": None,
    "blocking": ["x" * 300],
    "assumed": [],
    "outside_scope_needed": [],
    "paths": {"checked": True, "outside": []},
}))
PY
lessons_from "$TMP/long.json"
if python3 -I - "$TMP/out" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
data = [line for line in lines if line.startswith("- ")]
assert len(data) == 1, data
item = data[0].split("the spec left this open: ", 1)[1].split(". Rule:", 1)[0]
assert len(item) == 200, len(item)
assert item.endswith("\u2026"), item[-5:]
PY
then ok "a long item is cut to 200 characters with an ellipsis"; else
  bad "a long item was not cut to 200 characters"; sed 's/^/     /' "$TMP/out"
fi

# 4. Invalid JSON on stdin: a message on stderr and exit 2.
printf 'not json\n' > "$TMP/bad.json"
lessons_from "$TMP/bad.json"
rc=$?
if [ "$rc" = 2 ]; then ok "invalid stdin exits 2"; else bad "invalid stdin exits $rc, want 2"; fi
if grep -qi 'invalid' "$TMP/err"; then ok "invalid stdin explains itself on stderr"; else
  bad "invalid stdin error lacks 'invalid'"; sed 's/^/     /' "$TMP/err"
fi
if [ ! -s "$TMP/out" ]; then ok "invalid stdin prints nothing on stdout"; else bad "invalid stdin printed on stdout"; fi

# 5. End to end: `orchestra-worker lessons R1` on a fixture worktree prints the draft.
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
mkdir -p "$WT/other" "$WT/.orchestra/runs"
printf 'other\n' > "$WT/other/x.py"
cat > "$WT/.orchestra/report.json" <<'REPORT'
{
  "task": "R1",
  "status": "done",
  "summary": "implemented the greeting",
  "files_changed": ["src/a.py"],
  "checks": [{"command": "tests/run.sh", "result": "pass"}],
  "open_questions": ["Is the greeting name fixed?"],
  "assumptions": ["Used the existing greeting helper"],
  "out_of_scope_needed": ["docs need updating"],
  "acceptance": [{"item": "greeting prints", "met": true}]
}
REPORT
printf '{"exit":0,"secs":65}\n' > "$WT/.orchestra/runs/run-1.result.json"
printf '{"responses":23,"cost":0.012}\n' > "$WT/.orchestra/runs/run-1.usage.json"
: > "$WT/.orchestra/runs/run-1.jsonl"

( cd "$REPO" && ORCHESTRA_BASE=main ORCHESTRA_GATE='true' "$WORKER" lessons R1 ) > "$TMP/out" 2> "$TMP/err"
rc=$?
if [ "$rc" = 0 ]; then ok "orchestra-worker lessons exits 0"; else
  bad "orchestra-worker lessons exits $rc"; sed 's/^/     /' "$TMP/err"
fi
has "end-to-end header names the run" "# lessons draft for R1, run 1:"
line_has "end-to-end blocking line" "- $TODAY R1: the spec left this open: Is the greeting name fixed?. Rule: <write the rule>"
line_has "end-to-end outside path" "- $TODAY R1: the worker had to change \`other/x.py\`, outside Owns/Touches. Rule: <write the rule>"
line_has "end-to-end outside scope" "- $TODAY R1: the worker needed, outside scope: docs need updating. Rule: <write the rule>"
line_has "end-to-end assumption" "- $TODAY R1: the worker assumed: Used the existing greeting helper. Rule (only if it should have been decided): <write the rule>"

# 6. Lint: no `proof:` line is a warning (passes by default, fails with --strict); a proof line is silent.
LREPO="$TMP/lint"
mkdir -p "$LREPO/src" "$LREPO/docs/work/tasks"
git init -q -b main "$LREPO"
git -C "$LREPO" config user.email t@t
git -C "$LREPO" config user.name t
printf 'x\n' > "$LREPO/src/greet.py"
printf 'x\n' > "$LREPO/src/proof.py"
cat > "$LREPO/docs/work/tasks/P1-noproof.md" <<'SPEC'
---
id: P1
title: A task without a proof line
status: ready
depends: none
delegation: worker
---
## Owns
- `src/greet.py`

## Acceptance
- `python3 -m unittest -v`

## Out of scope
- nothing
SPEC
cat > "$LREPO/docs/work/tasks/P2-proof.md" <<'SPEC'
---
id: P2
title: A task with a proof line
status: ready
depends: none
delegation: worker
---
## Owns
- `src/proof.py`

## Acceptance
- proof: `python3 -m unittest -v`

## Out of scope
- nothing
SPEC
git -C "$LREPO" add -A
git -C "$LREPO" commit -qm init

( cd "$LREPO" && "$TASK_BIN" lint --base HEAD P1 ) > "$TMP/out" 2>&1
rc=$?
if [ "$rc" = 0 ]; then ok "lint passes a task without a proof line"; else bad "lint exits $rc on a task without a proof line"; fi
has "lint warns about the missing proof line" "warn:  L8 no proof: line: land will prove only the gate"
( cd "$LREPO" && "$TASK_BIN" lint --base HEAD --strict P1 ) > "$TMP/out" 2>&1
rc=$?
if [ "$rc" = 1 ]; then ok "lint --strict fails on the missing proof line"; else bad "lint --strict exits $rc, want 1"; fi
has "--strict still shows the warning" "warn:  L8 no proof: line: land will prove only the gate"
( cd "$LREPO" && "$TASK_BIN" lint --base HEAD P2 ) > "$TMP/out" 2>&1
rc=$?
if [ "$rc" = 0 ]; then ok "lint passes a task with a proof line"; else bad "lint exits $rc on a task with a proof line"; fi
hasnt "a proof line has no missing-proof warning" "L8 no proof: line"
( cd "$LREPO" && "$TASK_BIN" lint --base HEAD --strict P2 ) > "$TMP/out" 2>&1
rc=$?
if [ "$rc" = 0 ]; then ok "lint --strict passes a task with a proof line"; else bad "lint --strict exits $rc on a task with a proof line"; fi

printf 'lessons: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
