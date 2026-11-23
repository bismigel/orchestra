#!/usr/bin/env bash
# One run per task at a time, the ORCHESTRA_MAX_COST cap, and Ctrl-C: each stops the worker for real.
# Offline: a fake harness that spends $0.01 every 0.2 s until it is killed.
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W="$ROOT/bin/orchestra-worker"
TMP=$(mktemp -d); SLEEPER=""; trap 'kill $SLEEPER 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
export ORCHESTRA_TEST_ROOT=$ROOT XDG_CONFIG_HOME="$TMP/cfg" ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_TIMEOUT=60s
export ORCHESTRA_HARNESS="$ROOT/tests/fixtures/loop-harness.sh" ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1
git init -q -b main "$TMP/repo" && git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo "# spec" > "$TMP/repo/spec.md"
WT="$TMP/repo-worktrees"

# 1. The cap stops a run that keeps spending.
t0=$SECONDS
( cd "$TMP/repo" && ORCHESTRA_MAX_COST=0.05 "$W" run B1 --spec spec.md ) > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 5 ] && ok "over budget exits 5" || { bad "over budget: rc $rc"; sed 's/^/     /' "$TMP/out"; }
[ $((SECONDS - t0)) -lt 30 ] && ok "stopped well before the timeout" || bad "took $((SECONDS - t0))s"
grep -q "over budget: \$0.0600 > \$0.0500" "$TMP/out" && ok "progress says why it stopped" || bad "no over-budget line"
grep -q "exit 5 (OVER BUDGET" "$TMP/out" && ok "card explains exit 5" || bad "card lacks OVER BUDGET"
sleep 0.5; alive "$(cat "$WT/B1/.orchestra/loop.pid" 2>/dev/null)" && bad "the worker process survived" || ok "the worker process is gone"
[ ! -f "$WT/B1/.orchestra/run.json" ] && ok "run state removed" || bad "run.json left behind"
python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))["exit"] == 5' "$WT/B1/.orchestra/runs/run-1.result.json" \
  && ok "result file records exit 5" || bad "result file lacks exit 5"
# The cap also works with the progress lines turned off.
( cd "$TMP/repo" && ORCHESTRA_PROGRESS=0 ORCHESTRA_MAX_COST=0.03 "$W" run B2 --spec spec.md ) > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 5 ] && ok "cap enforced with ORCHESTRA_PROGRESS=0" || bad "quiet cap: rc $rc"
grep -q ' #1 \| quiet for' "$TMP/out" && bad "progress lines printed despite ORCHESTRA_PROGRESS=0" || ok "no progress lines when off"

# 2. A malformed cap refuses to start.
( cd "$TMP/repo" && ORCHESTRA_MAX_COST=lots "$W" run B3 --spec spec.md ) > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q "must be a number" "$TMP/out" && ok "malformed cap refused" || bad "malformed cap: rc $rc"

# 3. A second run on a task that is running is refused; a stale state file is cleared.
mkdir -p "$WT/B4/.orchestra"; git -C "$TMP/repo" worktree add -q -b orchestra/B4x "$WT/B4x" HEAD
sleep 300 & SLEEPER=$!
mkdir -p "$WT/B4x/.orchestra" && printf '{"task":"B4x","pid":%d,"run":1}' "$SLEEPER" > "$WT/B4x/.orchestra/run.json"
( cd "$TMP/repo" && "$W" run B4x --spec spec.md ) > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q "already running (pid $SLEEPER)" "$TMP/out" && ok "second run on a live task refused" || { bad "concurrent run: rc $rc"; sed 's/^/     /' "$TMP/out"; }
[ -f "$WT/B4x/.orchestra/run.json" ] && ok "the live run's state is untouched" || bad "live run.json removed"
kill $SLEEPER 2>/dev/null; wait $SLEEPER 2>/dev/null
( cd "$TMP/repo" && ORCHESTRA_MAX_COST=0.02 "$W" run B4x --spec spec.md ) > "$TMP/out" 2>&1; rc=$?
grep -q "removing stale run state" "$TMP/out" && [ "$rc" = 5 ] && ok "stale state cleared, run proceeds" || { bad "stale state: rc $rc"; sed 's/^/     /' "$TMP/out"; }

# 4. Stopping orchestra-worker stops the worker and cleans up: SIGTERM (how Claude Code and pi stop a background
#    command) and SIGINT (Ctrl-C). A script's background job starts with SIGINT ignored, so the INT case restores the
#    default handler first, as a terminal's foreground process has it.
for sig in TERM INT; do
  t="B5$sig"
  if [ "$sig" = INT ]; then
    ( cd "$TMP/repo" && exec python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' "$W" run "$t" --spec spec.md ) > "$TMP/out" 2>&1 & RUNNER=$!
  else
    ( cd "$TMP/repo" && exec "$W" run "$t" --spec spec.md ) > "$TMP/out" 2>&1 & RUNNER=$!
  fi
  for _ in $(seq 50); do [ -s "$WT/$t/.orchestra/loop.pid" ] && break; sleep 0.1; done
  kill -"$sig" $RUNNER; wait $RUNNER; rc=$?
  [ "$rc" = 130 ] && ok "SIG$sig: run exits 130" || { bad "SIG$sig: rc $rc"; sed 's/^/     /' "$TMP/out"; }
  sleep 0.5; alive "$(cat "$WT/$t/.orchestra/loop.pid" 2>/dev/null)" && bad "SIG$sig: worker survived" || ok "SIG$sig: worker stopped"
  [ ! -f "$WT/$t/.orchestra/run.json" ] && ok "SIG$sig: run state removed" || bad "SIG$sig: run.json left behind"
done

echo "budget: $pass passed, $fail failed"
[ "$fail" = 0 ]
