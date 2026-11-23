#!/usr/bin/env bash
# progress: pi_progress.py and watch_tail.py, offline and without a model.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROG="$ROOT/lib/harness/pi_progress.py"
WATCH="$ROOT/lib/watch_tail.py"
FIX="$ROOT/tests/fixtures/pi-progress.jsonl"
TMP=$(mktemp -d)
SPID=""
trap 'kill $SPID 2>/dev/null || true; rm -rf "$TMP"' EXIT
pass=0
fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# 1. snapshot on the fixture: exact counters, cost, last action, touched files.
out=$(python3 -I "$PROG" snapshot "$FIX" 2>"$TMP/snap.err")
rc=$?
if [ "$rc" != 0 ]; then
  bad "snapshot exits 0 on the fixture (rc $rc)"; sed 's/^/     /' "$TMP/snap.err"
elif python3 -I - "$out" "$FIX" <<'PY'
import json, os, sys
d = json.loads(sys.argv[1])
assert list(d) == ["tool_calls", "turns", "responses", "cost", "last_action", "last_activity", "files_touched"], list(d)
assert d["tool_calls"] == 8, d["tool_calls"]
assert d["turns"] == 2, d["turns"]
assert d["responses"] == 3, d["responses"]
assert isinstance(d["cost"], float) and abs(d["cost"] - 0.003) < 1e-9, d["cost"]
assert d["last_action"] == "read README.md", d["last_action"]
assert d["last_activity"] == int(os.path.getmtime(sys.argv[2])), d["last_activity"]
assert d["files_touched"] == ["internal/web/layout.templ", ".orchestra/report.json"], d["files_touched"]
PY
then
  ok "snapshot counts, cost, last action, files_touched (ignores message_update, non-JSON and a partial line)"
else
  bad "snapshot fixture values: $out"
fi

out=$(python3 -I "$PROG" snapshot "$TMP/no-such-log" 2>/dev/null)
rc=$?
if [ "$rc" = 1 ] && [ -z "$out" ]; then ok "snapshot: missing file exits 1 with no stdout"
else bad "snapshot: missing file rc $rc, out '$out'"; fi

# 2. Action text: bash whitespace collapses, a long bash command cuts to 72 chars ending in an ellipsis.
python3 -I - "$TMP/multi.jsonl" "$TMP/long.jsonl" <<'PY'
import json, sys
multi, long = sys.argv[1:]
with open(multi, "w") as f:
    f.write(json.dumps({"type": "session", "cwd": "/w"}) + "\n")
    f.write(json.dumps({"type": "tool_execution_start", "toolName": "bash",
                        "args": {"command": "echo one\n  echo two"}}) + "\n")
with open(long, "w") as f:
    f.write(json.dumps({"type": "session", "cwd": "/w"}) + "\n")
    f.write(json.dumps({"type": "tool_execution_start", "toolName": "bash",
                        "args": {"command": "x" * 100}}) + "\n")
PY
multi=$(python3 -I "$PROG" snapshot "$TMP/multi.jsonl")
long=$(python3 -I "$PROG" snapshot "$TMP/long.jsonl")
if python3 -I - "$multi" "$long" <<'PY'
import json, sys
m = json.loads(sys.argv[1])["last_action"]
l = json.loads(sys.argv[2])["last_action"]
assert m == "bash echo one echo two", m
command = l[len("bash "):]
assert len(command) == 72 and command.endswith("\u2026"), (len(command), command[-3:])
PY
then ok "bash action text: multi-line collapses, long command cuts to 72 with an ellipsis"
else bad "bash action text: multi '$multi' long '$long'"; fi

# 3. tail --lines 2 prints exactly the last two tool calls, oldest first.
expected=$(printf '#7 grep  foo\n#8 read  README.md')
out=$(python3 -I "$PROG" tail "$FIX" --lines 2)
if [ "$out" = "$expected" ]; then ok "tail --lines 2 prints exactly the last two tool calls"
else bad "tail --lines 2: got '$out', want '$expected'"; fi
out=$(python3 -I "$PROG" tail "$TMP/no-such-log" --lines 2 2>/dev/null)
rc=$?
if [ "$rc" = 1 ] && [ -z "$out" ]; then ok "tail: missing file exits 1"
else bad "tail: missing file rc $rc, out '$out'"; fi

# 4. follow: two complete tool lines, then a partial line, then SIGTERM.
log="$TMP/follow.log"
: > "$log"
python3 -I "$PROG" follow "$log" --task T41 --start "$(date +%s)" --poll 0.05 >"$TMP/follow.out" 2>&1 &
fp=$!
sleep 0.5
printf '%s\n' '{"type":"tool_execution_start","toolName":"bash","args":{"command":"echo one"}}' >>"$log"
printf '%s\n' '{"type":"tool_execution_start","toolName":"edit","args":{"path":"a.txt"}}' >>"$log"
printf '%s' '{"type":"tool_execution_start","toolName":"bash","args":{"command":"partial"}}' >>"$log"
sleep 0.5
kill -TERM "$fp" 2>/dev/null
wait "$fp"
frc=$?
follow_out=$(cat "$TMP/follow.out")
if [ "$frc" = 0 ]; then ok "follow exits 0 on SIGTERM"; else bad "follow SIGTERM rc $frc"; fi
if grep -q '#1 ' <<<"$follow_out" && grep -q '#2 ' <<<"$follow_out"; then ok "follow prints #1 and #2"
else bad "follow output lacks #1/#2: $follow_out"; fi
if grep -q '#3 ' <<<"$follow_out"; then bad "follow printed a partial line"; else ok "follow ignores the partial line"; fi
if [ "$(grep -c '■ done: 2 tool calls' <<<"$follow_out")" = 1 ]; then ok "follow prints exactly one done line"
else bad "follow done line count: $follow_out"; fi

# 5. follow exits by itself on agent_end, within 5 s.
log5="$TMP/agent-end.log"
{
  printf '%s\n' '{"type":"tool_execution_start","toolName":"read","args":{"path":"README.md"}}'
  printf '%s\n' '{"type":"agent_end"}'
} >"$log5"
out5=$(timeout 5 python3 -I "$PROG" follow "$log5" --task E1 --start "$(date +%s)" --poll 0.05)
rc5=$?
if [ "$rc5" = 0 ] && [ "$(grep -c '■ done: 1 tool calls' <<<"$out5")" = 1 ]; then
  ok "follow exits on agent_end with one done line"
else bad "follow agent_end: rc $rc5, out '$out5'"; fi

# 6. Heartbeat: a quiet line appears after 2 s with nothing to report.
log6="$TMP/quiet.log"
: > "$log6"
python3 -I "$PROG" follow "$log6" --task H1 --start "$(date +%s)" --heartbeat 1 --poll 0.05 >"$TMP/quiet.out" 2>&1 &
hp=$!
for _ in $(seq 1 40); do
  grep -q 'quiet for' "$TMP/quiet.out" && break
  sleep 0.1
done
kill -TERM "$hp" 2>/dev/null
wait "$hp"
if grep -q 'quiet for [1-9][0-9]*s' "$TMP/quiet.out"; then ok "follow --heartbeat prints a quiet line"
else bad "follow --heartbeat: $(cat "$TMP/quiet.out")"; fi

# 7. snapshot on a generated 15 MB log (mostly message_update) finishes in under 2 s.
python3 -I - "$TMP/big.jsonl" <<'PY'
import json, sys
payload = "x" * 100000
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "session", "cwd": "/w"}) + "\n")
    for _ in range(150):
        f.write(json.dumps({"type": "message_update", "message": {"content": payload}}) + "\n")
    for i in range(5):
        f.write(json.dumps({"type": "tool_execution_start", "toolName": "bash",
                            "args": {"command": f"echo {i}"}}) + "\n")
PY
big_bytes=$(wc -c <"$TMP/big.jsonl")
t0=$(date +%s%N)
big=$(python3 -I "$PROG" snapshot "$TMP/big.jsonl")
brc=$?
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [ "$brc" = 0 ] && [ "$ms" -lt 2000 ] && python3 -I - "$big" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["tool_calls"] == 5, d
PY
then ok "snapshot on a ${big_bytes}-byte log took ${ms} ms (< 2000 ms)"
else bad "snapshot on a large log: rc $brc, ${ms} ms, out '$big'"; fi

# 8. watch_tail: silent for a dead pid, a labelled block for a live one.
dead="$TMP/dead.json"
python3 -I - "$dead" "$FIX" "$PROG" <<'PY'
import json, sys
json.dump({"task": "T99", "pid": 999999, "kind": "run", "events": sys.argv[2], "progress": sys.argv[3]},
          open(sys.argv[1], "w"))
PY
out=$(python3 -I "$WATCH" "$dead" 2 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok "watch_tail prints nothing for a dead pid"
else bad "watch_tail dead pid: rc $rc, out '$out'"; fi

sleep 30 &
SPID=$!
live="$TMP/live.json"
python3 -I - "$live" "$FIX" "$PROG" "$SPID" <<'PY'
import json, sys
json.dump({"task": "T41", "pid": int(sys.argv[4]), "kind": "run", "events": sys.argv[2],
           "progress": sys.argv[3]}, open(sys.argv[1], "w"))
PY
out=$(python3 -I "$WATCH" "$live" 2 2>/dev/null)
rc=$?
if [ "$rc" = 0 ] && grep -q '^T41:$' <<<"$out" && grep -q '^  #8 read  README.md$' <<<"$out"; then
  ok "watch_tail prints the worker's last actions for a live pid"
else bad "watch_tail live pid: rc $rc, out '$out'"; fi

scout="$TMP/scout.json"
python3 -I - "$scout" "$FIX" "$PROG" "$SPID" <<'PY'
import json, sys
json.dump({"task": "T42", "pid": int(sys.argv[4]), "kind": "scout", "events": sys.argv[2],
           "progress": sys.argv[3]}, open(sys.argv[1], "w"))
PY
out=$(python3 -I "$WATCH" "$scout" 2 2>/dev/null)
if grep -q '^T42 (scout):$' <<<"$out"; then ok "watch_tail labels a scout run"
else bad "watch_tail scout label: '$out'"; fi

kill "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true
SPID=""

printf 'progress: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
