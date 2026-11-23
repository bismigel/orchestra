#!/usr/bin/env bash
# history: clean archives what it removes to a JSON Lines ledger, and history shows every task (live or cleaned)
# with its runs, cost and outcome, plus the project totals. Offline: no model calls, no network.
# Fixture (a temp repo on main, worktrees under <repo>-worktrees/):
#   A landed with 2 runs, a report and a denied egress host   B open (live) with 1 run
#   D dirty (never archived)                                  E running (never archived)
#   S1 scout with 1 run                                       C landed, used for the unwritable-ledger case
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
WORKER="$ROOT/bin/orchestra-worker"
TMP=$(mktemp -d)
XDG=$(mktemp -d)
REPO="$TMP/repo"
WT="$TMP/repo-worktrees"
LIVE=""
cleanup() {
  if [ -n "$LIVE" ]; then kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; fi
  chmod -R u+w "$TMP" 2>/dev/null
  rm -rf "$TMP" "$XDG"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { # check <name> <condition...>
  local name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
has()   { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (no '$2')"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then bad "$1 (found '$2')"; else ok "$1"; fi; }
row_has() { # row_has <description> <task> <kind> <runs>
  if grep -qF -- "$2 $3 $4" <<<"$(tr -s ' ' <<<"$OUT")"; then ok "$1"; else bad "$1: no '$2 $3 $4' row"; fi
}
exists()  { [ -d "$1" ]; }
is_gone() { [ ! -e "$1" ]; }
ledger_lines() { python3 -I -c 'import json,sys; print(len([json.loads(l) for l in open(sys.argv[1]) if l.strip()]))' "$1"; }
ledger_tasks() { python3 -I -c 'import json,sys
out=[]
for line in open(sys.argv[1]):
    try: out.append(json.loads(line)["task"])
    except Exception: pass
print(" ".join(sorted(out)))' "$1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
sleep 300 & LIVE=$!

build_fixture() (
  set -e
  git init -q -b main "$REPO"
  cd "$REPO"
  # orchestra writes these two lines when it runs a task in a worktree.
  printf '%s\n' '.orchestra/*' '!.orchestra/config.env' > .git/info/exclude
  echo base > base.txt
  git add base.txt
  git commit -qm init
  mkdir -p "$WT"

  # A: landed, with two runs (only the first has a result), a report and one denied egress host.
  git worktree add -q -b A "$WT/A" main
  ( cd "$WT/A"; echo a > a.txt; git add a.txt; git commit -qm "A: work" )
  git merge -q --ff-only A
  mkdir -p "$WT/A/.orchestra/runs"
  printf '{"responses":4,"cost":0.01}\n' > "$WT/A/.orchestra/runs/run-1.usage.json"
  printf '{"exit":0,"secs":60}\n'        > "$WT/A/.orchestra/runs/run-1.result.json"
  printf '{"responses":2,"cost":0.02}\n' > "$WT/A/.orchestra/runs/run-2.usage.json"
  printf '2026-01-01T00:00:00Z deny x.com:443\n' > "$WT/A/.orchestra/runs/run-1.egress.log"
  cat > "$WT/A/.orchestra/report.json" <<'REPORT'
{
  "task": "A",
  "status": "done",
  "summary": "landed the work",
  "files_changed": ["a.txt"],
  "checks": [{"command": "tests/all.sh", "result": "pass"}],
  "open_questions": ["Is the name fixed?", "Should it be localised?"],
  "assumptions": ["Used the existing helper."]
}
REPORT

  # B: open, still live, with one run.
  git worktree add -q -b B "$WT/B" main
  ( cd "$WT/B"; echo b > b.txt; git add b.txt; git commit -qm "B: work" )
  mkdir -p "$WT/B/.orchestra/runs"
  printf '{"responses":3,"cost":0.005}\n' > "$WT/B/.orchestra/runs/run-1.usage.json"

  # D: landed but dirty: never a candidate.
  git worktree add -q -b D "$WT/D" main
  ( cd "$WT/D"; echo d > d.txt; git add d.txt; git commit -qm "D: work" )
  git merge -q --ff-only D
  ( cd "$WT/D"; echo edit >> base.txt )

  # E: landed, with a live worker state file: never a candidate.
  git worktree add -q -b E "$WT/E" main
  ( cd "$WT/E"; echo e > e.txt; git add e.txt; git commit -qm "E: work" )
  git merge -q --ff-only E
  mkdir -p "$WT/E/.orchestra"
  printf '{"task": "E", "pid": %s}\n' "$LIVE" > "$WT/E/.orchestra/run.json"
)

if ! build_fixture > "$TMP/fixture.log" 2>&1; then
  bad "fixture"
  sed 's/^/     /' "$TMP/fixture.log"
  printf 'history: %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
ok "fixture"

LEDGER="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/orchestra/ledger.jsonl"
TODAY=$(date -u +%F)

run_clean() { ( cd "$REPO" && ORCHESTRA_BASE=main XDG_CONFIG_HOME="$XDG" "$WORKER" clean "$@" ); }
run_history() { ( cd "$REPO" && XDG_CONFIG_HOME="$XDG" "$WORKER" history "$@" ); }

# H2a. A listing without --yes creates no ledger at all.
OUT=$(run_clean 2>&1); rc=$?
check "listing exits 0" [ "$rc" = 0 ]
check "listing writes no ledger" [ ! -e "$LEDGER" ]
for t in A B D E; do check "listing kept worktree $t" exists "$WT/$t"; done

# H1. --yes archives A before removing it.
OUT=$(run_clean --yes 2>&1); rc=$?
check "clean --yes exits 0" [ "$rc" = 0 ]
check "clean --yes removed A" is_gone "$WT/A"
if grep -qF "removed A" <<<"$OUT"; then ok "clean --yes printed removed A"; else bad "clean --yes did not print removed A"; fi
check "the ledger has one line" [ "$(ledger_lines "$LEDGER")" = 1 ]
if python3 -I - "$LEDGER" <<'PY'
import json, sys
recs = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert len(recs) == 1, recs
r = recs[0]
assert r["task"] == "A" and r["kind"] == "task" and r["class"] == "landed", r
assert r["removed_at"].endswith("Z"), r["removed_at"]
assert r["branch"] == "A", r["branch"]
assert isinstance(r["head"], str) and len(r["head"]) == 40, r["head"]
assert [x["n"] for x in r["runs"]] == [1, 2], r["runs"]
first, second = r["runs"]
assert (first["exit"], first["secs"], first["responses"]) == (0, 60, 4), first
assert second["exit"] is None and second["secs"] is None, second
assert second["responses"] == 2, second
assert abs(r["cost"] - 0.03) < 1e-9, r["cost"]
assert len(r["report"]["blocking"]) == 2 and len(r["report"]["assumed"]) == 1, r["report"]
assert r["egress_denied"] == ["x.com:443"], r["egress_denied"]
print("ok")
PY
then ok "the ledger record has every field"; else bad "the ledger record is wrong"; fi

# H2b. A listing after the first removal leaves the same bytes.
BEFORE=$(cat "$LEDGER")
OUT=$(run_clean 2>&1); rc=$?
check "second listing exits 0" [ "$rc" = 0 ]
check "a listing leaves the ledger byte for byte" [ "$(cat "$LEDGER")" = "$BEFORE" ]

# H3. history shows the cleaned task (dated) and the live one, with the runs and cost of both.
OUT=$(run_history 2>&1); rc=$?
check "history exits 0" [ "$rc" = 0 ]
if head -n1 <<<"$OUT" | grep -qE '^TASK +KIND +RUNS +COST +STATUS +BLOCKING +ASSUMED +WHEN$'; then
  ok "the header has the history columns"
else bad "wrong header: $(head -n1 <<<"$OUT")"; fi
row_has "A is a cleaned task with 2 runs" A  task  2
row_has "B is a live task with 1 run"    B  task  1
has "A carries its report status" "done" "$OUT"
has "A is dated (YYYY-MM-DD)" "$TODAY" "$OUT"
if grep -qE '(^| )B +task +1 .* live$' <<<"$OUT"; then ok "B is shown as live"; else bad "B is not shown as live: $OUT"; fi
has "the total counts both tasks and all 3 runs" "total: 2 tasks, 3 runs, \$0.0350" "$OUT"

# H5. A scout is archived as its own kind, and counts in runs and cost but not in tasks.
mkdir -p "$WT/.scout/S1/runs"
printf '{"responses":1,"cost":0.001}\n' > "$WT/.scout/S1/runs/run-1.usage.json"
OUT=$(run_clean --yes 2>&1); rc=$?
check "the scout clean exits 0" [ "$rc" = 0 ]
check "S1 is gone" is_gone "$WT/.scout/S1"
if python3 -I - "$LEDGER" <<'PY'
import json, sys
recs = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert len(recs) == 2, recs
scout = [r for r in recs if r["kind"] == "scout"]
assert len(scout) == 1 and scout[0]["task"] == "S1", scout
assert scout[0]["removed_at"].endswith("Z"), scout[0]
assert [x["n"] for x in scout[0]["runs"]] == [1], scout[0]["runs"]
assert abs(scout[0]["cost"] - 0.001) < 1e-9, scout[0]["cost"]
print("ok")
PY
then ok "S1 is archived as kind scout with its run and cost"; else bad "the scout ledger record is wrong"; fi
OUT=$(run_history 2>&1)
row_has "S1 is a scout with 1 run" S1 scout 1
has "scouts count in runs and cost, not in tasks" "total: 2 tasks, 4 runs, \$0.0360" "$OUT"

# H6. A malformed ledger line is skipped, counted on stderr, and the rows still print.
printf 'this is not json\n' >> "$LEDGER"
OUT=$(run_history 2>"$TMP/h6.err"); rc=$?
check "history with a malformed line exits 0" [ "$rc" = 0 ]
row_has "A still prints next to a malformed line" A task 2
has "the malformed line is counted on stderr" "history: skipped 1 malformed ledger line(s)" "$(cat "$TMP/h6.err")"

# H7. --json gives the same rows as data, each marked live or not, and the totals.
JS=$(run_history --json 2>/dev/null); rc=$?
check "history --json exits 0" [ "$rc" = 0 ]
if python3 -I - "$JS" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == {"rows", "total"}, d
assert set(d["total"]) == {"tasks", "runs", "cost"}, d["total"]
assert d["total"]["tasks"] == 2 and d["total"]["runs"] == 4, d["total"]
assert abs(d["total"]["cost"] - 0.036) < 1e-9, d["total"]
assert len(d["rows"]) == 3, d["rows"]
assert all(isinstance(r.get("live"), bool) for r in d["rows"]), d["rows"]
by = {(r["task"], r["kind"]): r for r in d["rows"]}
assert by[("A", "task")]["live"] is False, by[("A", "task")]
assert by[("S1", "scout")]["live"] is False, by[("S1", "scout")]
assert by[("B", "task")]["live"] is True, by[("B", "task")]
assert by[("A", "task")]["report"]["status"] == "done", by[("A", "task")]
print("ok")
PY
then ok "--json rows and totals are right"; else bad "--json is wrong: $JS"; fi

# H4. An unwritable ledger directory keeps the entry: printed, not removed, exit 1.
git -C "$REPO" worktree add -q -b C "$WT/C" main
( cd "$WT/C"; echo c > c.txt; git add c.txt; git commit -qm "C: work" )
git -C "$REPO" merge -q --ff-only C
LEDGER_DIR=$(dirname "$LEDGER")
chmod a-w "$LEDGER_DIR" "$LEDGER"
OUT=$(run_clean --yes 2>&1); rc=$?
chmod u+w "$LEDGER_DIR" "$LEDGER"
check "a failed archive exits 1" [ "$rc" = 1 ]
check "C is not removed when it cannot be archived" exists "$WT/C"
if grep -qF "could not archive C" <<<"$OUT"; then ok "the failed archive is printed"; else bad "no archive error: $OUT"; fi
hasnt "C is not printed as removed" "removed C" "$OUT"

# H8. Dirty and running worktrees are never archived and never removed; C goes once the ledger is writable.
OUT=$(run_clean --yes 2>&1); rc=$?
check "clean --yes after the ledger is writable exits 0" [ "$rc" = 0 ]
check "C is removed once the ledger is writable" is_gone "$WT/C"
for t in D E; do
  check "the dirty/running worktree $t is still there" exists "$WT/$t"
  hasnt "$t was not archived" "\"task\": \"$t\"" "$(cat "$LEDGER")"
done
if grep -qx 'A S1\|A C S1' <<<"$(ledger_tasks "$LEDGER")"; then ok "only the landed tasks are in the ledger"; else bad "unexpected ledger tasks: $(ledger_tasks "$LEDGER")"; fi

# A repository with no ledger and no worktrees is empty, not an error.
EMPTY="$TMP/emptyrepo"
git init -q -b main "$EMPTY"
git -C "$EMPTY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
OUT=$( cd "$EMPTY" && XDG_CONFIG_HOME="$XDG" "$WORKER" history 2>&1 ); rc=$?
check "history without a ledger or worktrees exits 0" [ "$rc" = 0 ]
has "empty history says no history" "no history" "$OUT"
JS=$( cd "$EMPTY" && XDG_CONFIG_HOME="$XDG" "$WORKER" history --json 2>/dev/null )
if python3 -I - "$JS" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["rows"] == [], d
assert d["total"] == {"tasks": 0, "runs": 0, "cost": 0}, d["total"]
print("ok")
PY
then ok "empty --json has no rows and zero totals"; else bad "empty --json is wrong: $JS"; fi

printf 'history: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
