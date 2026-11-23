#!/usr/bin/env bash
# Egress allowlist (ORCHESTRA_EGRESS_ALLOW): inside the sandbox only listed hosts are reachable, through the proxy.
# Offline: two echo servers on the host's loopback stand in for the internet. Needs bubblewrap with namespaces.
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W="$ROOT/bin/orchestra-worker"
TMP=$(mktemp -d); PIDS=""; trap 'kill $PIDS 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 (no '$2' in $(basename "$3"))"; sed 's/^/     /' "$3"; fi; }

# Allowlist matching, straight from the proxy module.
python3 -I - "$ROOT/lib" <<'PY' && ok "allowlist matching rules" || bad "allowlist matching rules"
import sys; sys.path.insert(0, sys.argv[1]); import egress_proxy as e
r = e.parse_rules("api.deepseek.com, *.npmjs.org registry.local:8443 10.0.0.5")
assert e.allowed("api.deepseek.com", 443, r) and e.allowed("API.DeepSeek.com.", 443, r)
assert not e.allowed("api.deepseek.com", 80, r)               # bare host means 443 only
assert not e.allowed("evil.com", 443, r) and not e.allowed("api.deepseek.com.evil.com", 443, r)
assert e.allowed("registry.npmjs.org", 443, r) and not e.allowed("npmjs.org", 443, r)   # wildcard: subdomains only
assert not e.allowed("xnpmjs.org", 443, r)
assert e.allowed("registry.local", 8443, r) and not e.allowed("registry.local", 443, r)
assert e.allowed("10.0.0.5", 443, r) and not e.allowed("10.0.0.6", 443, r)
for badrule in ("http://x.com", "x.com:99999", "a b/c", "*."):
    try: e.parse_rules(badrule); raise SystemExit("accepted " + badrule)
    except ValueError: pass
assert e.parse_connect(b"CONNECT a.com:443 HTTP/1.1\r\n\r\n") == ("a.com", 443)
assert e.parse_connect(b"GET http://a.com/ HTTP/1.1\r\n\r\n") is None
assert e.parse_connect(b"CONNECT a.com:443@evil.com:443 HTTP/1.1\r\n\r\n") is None
PY

if ! command -v bwrap >/dev/null || ! bwrap --unshare-net --ro-bind / / true 2>/dev/null; then
  echo "skip sandbox tests: bubblewrap cannot create namespaces here"; echo "egress: $pass passed, $fail failed"; [ "$fail" = 0 ]; exit; fi

# Two echo servers on the host: one allowed, one not.
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
OKP=$(port); NOP=$(port)
for p in "$OKP" "$NOP"; do
  python3 -I -c '
import socket, sys, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen()
def echo(c):
    with c:
        while (d := c.recv(4096)): c.sendall(d)
while True: threading.Thread(target=echo, args=(s.accept()[0],), daemon=True).start()' "$p" & PIDS="$PIDS $!"
done
sleep 0.5

git init -q -b main "$TMP/repo" && git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo "# spec" > "$TMP/repo/spec.md"
export XDG_CONFIG_HOME="$TMP/cfg" ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_HARNESS="$ROOT/tests/fixtures/egress-harness.sh"
export ORCHESTRA_SANDBOX=bwrap FAKE_OK_PORT=$OKP FAKE_NO_PORT=$NOP ORCHESTRA_PROGRESS=0

BEFORE_DIRS=$(ls -d /tmp/orchestra-egress.* 2>/dev/null | wc -l)
( cd "$TMP/repo" && ORCHESTRA_EGRESS_ALLOW="localhost:$OKP" "$W" run E1 --spec spec.md ) > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "confined run exits 0" || { bad "confined run exit $rc"; sed 's/^/     /' "$TMP/out"; }
ERR="$TMP/repo-worktrees/E1/.orchestra/runs/run-1.err"
has "proxy variables set inside"           "probe: proxy-env set"   "$ERR"
has "listed host reachable via the proxy"  "probe: allowed echo-ok" "$ERR"
has "unlisted host refused (403)"          "probe: denied 403"      "$ERR"
has "plain HTTP refused (403)"             "probe: plain-http 403"  "$ERR"
has "direct connection blocked"            "probe: direct blocked"  "$ERR"
has "DNS blocked"                          "probe: dns blocked"     "$ERR"
LOG="$TMP/repo-worktrees/E1/.orchestra/runs/run-1.egress.log"
has "log records the allowed host"         "allow localhost:$OKP"   "$LOG"
has "log records the denied host"          "deny localhost:$NOP"    "$LOG"
has "finish card counts egress"            "1 allowed · 2 host(s) denied" "$TMP/out"
if [ "$(ls -d /tmp/orchestra-egress.* 2>/dev/null | wc -l)" = "$BEFORE_DIRS" ] && ! pgrep -f "[e]gress_proxy.py --socket /tmp/orchestra-egress" >/dev/null; then
  ok "proxy stopped and socket removed"; else bad "proxy or its socket left behind: dirs $(ls -d /tmp/orchestra-egress.* 2>/dev/null) before $BEFORE_DIRS procs $(pgrep -af "[e]gress_proxy.py --socket")"; fi

# Without an allowlist the sandbox keeps the host network (unchanged behaviour): the direct probe gets through.
( cd "$TMP/repo" && "$W" run E2 --spec spec.md ) > "$TMP/out" 2>&1
has "default run keeps the host network"   "probe: direct LEAK" "$TMP/repo-worktrees/E2/.orchestra/runs/run-1.err"

# Refusals: an allowlist without a sandbox, and a malformed allowlist.
( cd "$TMP/repo" && ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1 ORCHESTRA_EGRESS_ALLOW=x.com "$W" run E3 --spec spec.md ) > "$TMP/out" 2>&1
[ $? = 2 ] && ok "allowlist without bwrap refused" || bad "allowlist without bwrap not refused"
( cd "$TMP/repo" && ORCHESTRA_EGRESS_ALLOW='http://x.com' "$W" run E4 --spec spec.md ) > "$TMP/out" 2>&1
[ $? = 2 ] && grep -q "bad egress allowlist entry" "$TMP/out" && ok "malformed allowlist refused before the run" || { bad "malformed allowlist not refused"; sed 's/^/     /' "$TMP/out"; }
[ ! -e "$TMP/repo-worktrees/E4/.orchestra/runs/run-1.jsonl" ] || [ ! -s "$TMP/repo-worktrees/E4/.orchestra/runs/run-1.jsonl" ] && ok "no worker ran unconfined" || bad "a worker ran despite a bad allowlist"

echo "egress: $pass passed, $fail failed"
[ "$fail" = 0 ]
