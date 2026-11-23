#!/usr/bin/env bash
# status: a live run is reported running, a dead one is reported stale, and the JSON is machine-readable.
# Offline: no model calls. Fixture worktrees are named so `status --json` can be checked structurally.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKER="$ROOT/bin/orchestra-worker"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# A repository whose sibling worktree base holds the fixture state files.
REPO="$TMP/repo"; mkdir -p "$REPO" "$TMP/repo-worktrees/T01/.orchestra" "$TMP/repo-worktrees/T02/.orchestra"
git -C "$REPO" init -q 2>/dev/null || true
git -C "$REPO" rev-parse --show-toplevel >/dev/null || { echo "fixture is not a git repo"; exit 1; }

# A process that is definitely alive, and a pid that definitely is not.
sleep 300 & LIVE=$!
DEAD=999999
python3 -I - "$TMP/repo-worktrees/T01/.orchestra/run.json" "$LIVE" <<'PY'
import json, sys, time
path, pid = sys.argv[1:]
json.dump({"task": "T01", "pid": int(pid), "run": 1, "worktree": path.rsplit("/.orchestra/", 1)[0],
           "model": "deepseek/deepseek-flash", "harness": "pi", "profile": "dev",
           "started": int(time.time()) - 125, "started_at": "2026-01-01T00:00:00Z"}, open(path, "w"))
PY
python3 -I - "$TMP/repo-worktrees/T02/.orchestra/run.json" "$DEAD" <<'PY'
import json, sys, time
path, pid = sys.argv[1:]
json.dump({"task": "T02", "pid": int(pid), "run": 1, "worktree": path.rsplit("/.orchestra/", 1)[0],
           "model": "deepseek/deepseek-flash", "harness": "pi", "profile": "dev",
           "started": int(time.time()) - 7260, "started_at": "2026-01-01T00:00:00Z"}, open(path, "w"))
PY

out=$(cd "$REPO" && "$WORKER" status 2>/dev/null)
grep -q "T01 .*running" <<<"$out" && ok "live pid reported running" || bad "live pid not reported running: $out"
grep -q "T02 .*stale"   <<<"$out" && ok "dead pid reported stale"   || bad "dead pid not reported stale: $out"
grep -q "2m05s"         <<<"$out" && ok "elapsed formatted from started" || bad "elapsed missing: $out"
grep -q "T02" <<<"$(cd "$REPO" && "$WORKER" status 2>&1 >/dev/null)" && ok "stale run explained on stderr" || bad "no stale hint"

js=$(cd "$REPO" && "$WORKER" status --json 2>/dev/null)
python3 -I - "$js" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["running"] == 1, d["running"]
by = {r["task"]: r for r in d["runs"]}
assert by["T01"]["state"] == "running", by["T01"]
assert by["T02"]["state"] == "stale", by["T02"]
assert by["T01"]["elapsed_seconds"] >= 120, by["T01"]
assert by["T01"]["model"] and by["T01"]["worktree"], by["T01"]
print("ok   --json shape")
PY
[ $? = 0 ] && pass=$((pass+1)) || bad "--json shape"

# No state files at all: a positive-looking empty answer, not an error.
mkdir -p "$TMP/empty" && git -C "$TMP/empty" init -q 2>/dev/null && out=$(cd "$TMP/empty" && "$WORKER" status 2>&1)
grep -q "no runs" <<<"$out" && ok "no runs reported when nothing is running" || bad "expected 'no runs', got: $out"
js=$(cd "$TMP/empty" && "$WORKER" status --json 2>/dev/null)
python3 -I - "$js" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["running"] == 0 and d["runs"] == [], d
print("ok   --json empty")
PY
[ $? = 0 ] && pass=$((pass+1)) || bad "--json empty"

kill "$LIVE" 2>/dev/null || true
printf 'status: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
