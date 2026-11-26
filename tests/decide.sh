#!/usr/bin/env bash
# decide: Jev as an advisory second opinion (lib/decide.py, config/decisions.json). Offline: a fake Workers AI endpoint
# on localhost stands in for Cloudflare, so there are no model calls and no external network. Checks: off makes no
# call, the wire format and the bearer header, redaction of what is sent, the token never reaching a log or output,
# split/ready/triage verdicts, that Jev can only raise attention (the deterministic floor), that a failure never
# changes an exit code, the shadow/advise hooks in run and review, and mark/report.
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W="$ROOT/bin/orchestra-worker"
DECIDE="$ROOT/lib/decide.py"
TMP=$(mktemp -d); SRV=""
cleanup() { [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }; rm -rf "$TMP"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
has() { grep -qF -- "$2" <<<"$1"; }

# ---- the fake endpoint: records every request, answers from $TMP/scenario.json -------------------------------------
cat > "$TMP/server.py" <<'PY'
import http.server, json, os, sys
tmp = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with open(os.path.join(tmp, "requests.jsonl"), "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"),
                                "ua": self.headers.get("User-Agent"), "body": body}) + "\n")
        sc = json.load(open(os.path.join(tmp, "scenario.json")))
        if sc.get("status", 200) != 200:
            self.send_response(sc["status"]); self.end_headers(); self.wfile.write(b'{"success":false}'); return
        answers = sc["answers"]
        out = {"success": True, "result": {"state": "Completed", "result": {"answers": answers, "usage": {"total": 1}}}}
        data = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(data)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(tmp, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$TMP/server.py" "$TMP" & SRV=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT=$(cat "$TMP/port")
URL="http://127.0.0.1:$PORT/accounts/{account}/ai/run"
reqs() { [ -f "$TMP/requests.jsonl" ] && wc -l < "$TMP/requests.jsonl" || echo 0; }
choice() { # choice <question> <label=prob>...  -> an answers fragment
  python3 -I - "$@" <<'PY'
import json, sys
q, *pairs = sys.argv[1:]
probs = {k: float(v) for k, v in (p.split("=") for p in pairs)}
print(json.dumps({q: {"type": "choice", "choice": max(probs, key=probs.get), "probabilities": probs, "confidence": max(probs.values())}}))
PY
}
scenario() { # scenario <answers fragment>... : what the fake endpoint answers from now on
  python3 -I -c 'import json,sys
ans = {}
for a in sys.argv[2:]: ans.update(json.loads(a))
json.dump({"answers": ans}, open(sys.argv[1], "w"))' "$TMP/scenario.json" "$@"
}
bools() { # bools q=p ...
  python3 -I -c 'import json,sys; print(json.dumps({k: {"type": "noul", "noul": float(v)} for k, v in (a.split("=") for a in sys.argv[1:])}))' "$@"
}
fail_status() { printf '{"status": %s, "answers": {}}' "$1" > "$TMP/scenario.json"; }

# ---- repository and config ---------------------------------------------------------------------------------------
git init -q -b main "$TMP/repo" && git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat > "$TMP/repo/spec.md" <<'EOF'
---
id: D1
title: Add a greeting
status: ready
depends: none
delegation: worker
---
## Goal
Add `greet()`. Deploy host 10.4.5.6 and mail ops@example.org. Use API_TOKEN=sk-live-abcdef0123456789abcdef0123456789 ok.
Also 0123456789abcdef0123456789abcdef01234567 is a hash.
## Owns
- `hello/`
## Acceptance
- proof: `true`
## Out of scope
Everything else.
EOF
export XDG_CONFIG_HOME="$TMP/cfg" ORCHESTRA_TEST_ROOT="$ROOT"
export ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_ALLOWED_MODELS=fake/worker-1 ORCHESTRA_BASE=main
export ORCHESTRA_HARNESS="$ROOT/tests/fixtures/fake-harness.sh" FAKE_MODEL=fake/worker-1
export ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1 ORCHESTRA_KEY_ENV=
unset ORCHESTRA_JEV ORCHESTRA_JEV_URL ORCHESTRA_JEV_KEY_CMD ORCHESTRA_JEV_ACCOUNT_ID
TOKEN=cf-test-token-0a1b2c3d4e5f
jev_env() { export ORCHESTRA_JEV=$1 ORCHESTRA_JEV_URL="$URL" ORCHESTRA_JEV_ACCOUNT_ID=acct123 ORCHESTRA_JEV_KEY_CMD="printf %s $TOKEN"; }
cd "$TMP/repo" || exit 1
LOG="$TMP/repo/.git/orchestra/decisions.jsonl"

# ---- off: nothing is sent, and asking by hand says why -----------------------------------------------------------
scenario "$(choice route worker=0.9 split=0.05 orchestrator=0.05)"
out=$("$W" decide split D1 --spec spec.md 2>&1); rc=$?
[ "$rc" = 2 ] && has "$out" "ORCHESTRA_JEV=off" && ok "off: asking by hand exits 2 and says how to turn it on" || { bad "off decide: rc $rc"; echo "$out"; }
out=$("$W" run D1 --spec spec.md 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(reqs)" = 0 ] && [ ! -f "$LOG" ] && ok "off: run makes no request and writes no log" || bad "off run: rc $rc, requests $(reqs)"
out=$(ORCHESTRA_JEV=bogus "$W" decide report 2>&1); rc=$?
[ "$rc" = 2 ] && has "$out" "off, shadow or advise" && ok "an unknown ORCHESTRA_JEV value is a config error" || bad "bogus mode: rc $rc"
out=$("$W" doctor 2>&1 || true); has "$out" "jev: off" && ok "doctor reports jev: off" || bad "doctor off"

# ---- split by hand: wire format, bearer, redaction ---------------------------------------------------------------
jev_env shadow
out=$("$W" decide split D1 --spec spec.md 2>&1); rc=$?
[ "$rc" = 0 ] && ok "split by hand exits 0" || { bad "split rc $rc"; echo "$out"; }
has "$out" "jev [split] worker (P(worker)=0.90)" && ok "a confident worker answer reads as worker" || { bad "split line"; echo "$out"; }
has "$out" "advisory" && ok "the verdict says it is advisory" || bad "advisory note"
req=$(tail -n1 "$TMP/requests.jsonl")
python3 -I - "$req" "$TOKEN" <<'PY' && ok "request: POST /accounts/acct123/ai/run, bearer token, model typesafe/jev, state.spec, questions" || bad "request shape"
import json, sys
r = json.loads(sys.argv[1]); b = json.loads(r["body"])
assert r["path"] == "/accounts/acct123/ai/run", r["path"]
assert r["auth"] == "Bearer " + sys.argv[2]
assert b["model"] == "typesafe/jev" and "spec" in b["input"]["state"]
assert b["input"]["questions"]["route"]["type"] == "choice"
PY
python3 -I - "$req" <<'PY' && ok "redaction: the secret, the long hash, the private IP and the email never leave the machine" || { bad "redaction"; echo "$req" | head -c 600; }
import json, sys
body = json.loads(json.loads(sys.argv[1])["body"])["input"]["state"]["spec"]
for secret in ("sk-live-abcdef0123456789abcdef0123456789", "0123456789abcdef0123456789abcdef01234567", "10.4.5.6", "ops@example.org"):
    assert secret not in body, secret
assert "Add `greet()`" in body
PY
grep -qF "$TOKEN" "$LOG" && bad "the API token reached the decisions log" || ok "the token is never written to the log"
has "$out" "$TOKEN" && bad "the token was printed" || ok "the token is never printed"

# ---- split: Jev can only raise attention -------------------------------------------------------------------------
scenario "$(choice route worker=0.3 split=0.6 orchestrator=0.1)"
out=$("$W" decide split D1 --spec spec.md 2>&1)
has "$out" "jev [split] split (P(worker)=0.30); spec says worker" && has "$out" "flag: split? P(worker)=0.30" && ok "spec says worker, Jev says split: flagged" || { bad "split flag"; echo "$out"; }
sed -i 's/^delegation: worker/delegation: split/' spec.md
out=$("$W" decide split D1 --spec spec.md 2>&1)
has "$out" "flag:" && bad "Jev agreeing with a split spec must not flag" || ok "spec already says split: no flag"
scenario "$(choice route worker=0.95 split=0.03 orchestrator=0.02)"
out=$("$W" decide split D1 --spec spec.md 2>&1)
has "$out" "flag:" && bad "Jev saying worker on a split spec must not flag (no de-escalation prompts)" || ok "Jev wanting less scrutiny is logged, never flagged"
sed -i 's/^delegation: split/delegation: worker/' spec.md

# ---- ready -------------------------------------------------------------------------------------------------------
scenario "$(bools decisions=0.9 tests=0.2 paths=0.95 proof=0.9 scope=0.8)"
out=$("$W" decide ready D1 --spec spec.md 2>&1)
has "$out" "not-ready" && has "$out" "flag: spec may not be ready: tests (P=0.20)" && ok "ready: a bool under 0.5 is named" || { bad "ready flag"; echo "$out"; }
req=$(tail -n1 "$TMP/requests.jsonl")
python3 -I - "$req" <<'PY' && ok "bool questions go on the wire as type noul" || bad "noul wire type"
import json, sys
q = json.loads(json.loads(sys.argv[1])["body"])["input"]["questions"]
assert all(v["type"] == "noul" for v in q.values()) and set(q) == {"decisions", "tests", "paths", "proof", "scope"}
PY
scenario "$(bools decisions=0.9 tests=0.8 paths=0.95 proof=0.9 scope=0.8)"
out=$("$W" decide ready D1 --spec spec.md 2>&1)
has "$out" "flag:" && bad "a ready spec must not flag" || ok "ready: all bools high: no flag"

# ---- triage: a deterministic floor Jev can only raise ------------------------------------------------------------
mkreview() { # mkreview [json override of top-level keys]... : the review digest Jev reads
  python3 -I -c 'import json,sys
d = json.loads(sys.argv[1])
for o in sys.argv[2:]: d.update(json.loads(o))
print(json.dumps(d))' "$base" "$@" > "$TMP/review.json"
}
base='{"report_valid":true,"status":"done","summary":"ok","blocking":[],"assumed":[],"outside_scope_needed":[],"risk_notes":[],"paths":{"checked":true,"outside":[]},"worker_checks":{"pass":2,"fail":0,"failing":[]},"acceptance":null,"proofs":{"checks":[{"check":"t","state":"pass"}],"manual":[]},"diff":{"files":1,"added":5,"removed":0},"run":{"exit":0}}'
run_triage() { python3 -I "$DECIDE" run --kind triage --task D1 --log "$LOG" --decisions "$ROOT/config/decisions.json" --review-json "$TMP/review.json" --print always 2>&1; }
mkreview; scenario "$(choice verdict clean=0.9 look=0.07 block=0.03)"
out=$(run_triage); has "$out" "jev [triage] clean" && ! has "$out" "flag:" && ok "clean facts and Jev clean: clean, no flag" || { bad "triage clean"; echo "$out"; }
scenario "$(choice verdict clean=0.2 look=0.7 block=0.1)"
out=$(run_triage); has "$out" "jev [triage] look" && has "$out" "flag: look, above the facts' clean" && ok "Jev raises clean facts to look" || { bad "triage raise"; echo "$out"; }
mkreview '{"proofs":{"checks":[{"check":"t","state":"fail"}],"manual":[]}}'
scenario "$(choice verdict clean=0.97 look=0.02 block=0.01)"
out=$(run_triage); has "$out" "jev [triage] block" && has "$out" "a proof failed" && ! has "$out" "flag:" && ok "a failed proof is block even when Jev says clean (the floor)" || { bad "triage floor"; echo "$out"; }
mkreview '{"risk_notes":["rotate the token sk-live-abcdef0123456789abcdef0123456789"]}'
scenario "$(choice verdict clean=0.97 look=0.02 block=0.01)"
out=$(run_triage); has "$out" "jev [triage] look" && has "$out" "risk notes" && ok "risk notes floor the verdict at look" || { bad "risk notes floor"; echo "$out"; }
tail -n1 "$TMP/requests.jsonl" | grep -qF "sk-live-abcdef" && bad "a secret in a risk note was sent" || ok "triage state is redacted too"
tail -n1 "$TMP/requests.jsonl" | grep -q '"diff"' && bad "the diff must not be sent" || true

# ---- failures never change an exit code, and say so --------------------------------------------------------------
fail_status 500
out=$("$W" decide split D1 --spec spec.md 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "jev [split] unavailable: HTTP 500" && ok "HTTP 500: unavailable, exit 0" || { bad "http 500: rc $rc"; echo "$out"; }
out=$(ORCHESTRA_JEV_KEY_CMD=false "$W" decide split D1 --spec spec.md 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "ORCHESTRA_JEV_KEY_CMD gave no key" && ok "a failing key command: unavailable, exit 0" || { bad "key cmd: rc $rc"; echo "$out"; }
out=$(ORCHESTRA_JEV_ACCOUNT_ID="" "$W" decide split D1 --spec spec.md 2>&1); rc=$?
has "$out" "ORCHESTRA_JEV_ACCOUNT_ID is not set" && ok "a missing account id is named" || { bad "account id: rc $rc"; echo "$out"; }
out=$(ORCHESTRA_JEV_URL="http://127.0.0.1:1/x" "$W" decide split D1 --spec spec.md 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "unavailable" && ok "an unreachable endpoint: unavailable, exit 0" || { bad "unreachable: rc $rc"; echo "$out"; }
grep -qF "$TOKEN" "$LOG" && bad "token in the log after failures" || ok "no token in the log after failures"
before=$(reqs)
out=$(ORCHESTRA_JEV_REDACT='(' "$W" decide split D1 --spec spec.md 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "ORCHESTRA_JEV_REDACT is not a valid regular expression" && [ "$(reqs)" = "$before" ] \
  && ok "a bad ORCHESTRA_JEV_REDACT regex fails closed: named, nothing is sent" || { bad "bad redact: rc $rc, requests $before -> $(reqs)"; echo "$out"; }
scenario "$(choice route worker=0.9 split=0.05 orchestrator=0.05)"
ORCHESTRA_JEV_REDACT='greeting' "$W" decide split D1 --spec spec.md >/dev/null 2>&1
tail -n1 "$TMP/requests.jsonl" | grep -qi 'greeting' && bad "ORCHESTRA_JEV_REDACT not applied" || ok "ORCHESTRA_JEV_REDACT removes extra patterns"

# ---- hooks: shadow logs quietly, advise prints flags only; review --json stays one object ------------------------------
scenario "$(choice route worker=0.3 split=0.6 orchestrator=0.1)"
: > "$TMP/requests.jsonl"; rm -f "$LOG"
out=$(ORCHESTRA_JEV=shadow "$W" run H1 --spec spec.md 2>&1); rc=$?
[ "$rc" = 0 ] && ! has "$out" "jev [" && [ "$(reqs)" = 2 ] && ok "shadow: run asks Jev twice (split, ready), prints nothing" || { bad "shadow run: rc $rc, requests $(reqs)"; echo "$out"; }
[ "$(wc -l < "$LOG")" = 2 ] && ok "shadow: both answers are logged" || bad "shadow log lines: $(wc -l < "$LOG")"
: > "$TMP/requests.jsonl"
out=$(ORCHESTRA_JEV=advise "$W" run H2 --spec spec.md 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "jev [split] split? P(worker)=0.30" && ok "advise: run prints the split flag" || { bad "advise run: rc $rc"; echo "$out"; }
: > "$TMP/requests.jsonl"
out=$(ORCHESTRA_JEV=advise "$W" review H2 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(reqs)" = 1 ] && ok "advise: review asks for a triage verdict" || { bad "advise review: rc $rc, requests $(reqs)"; echo "$out"; }
: > "$TMP/requests.jsonl"
out=$(ORCHESTRA_JEV=advise "$W" review H2 --json 2>&1); rc=$?
python3 -I -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" 2>/dev/null && [ "$(reqs)" = 0 ] && ok "review --json stays one parseable object and makes no call" || { bad "review --json: rc $rc"; echo "$out" | head -5; }
out=$(ORCHESTRA_JEV=advise "$W" run H3 --prompt "do a thing" 2>&1) ; [ "$(reqs)" = 0 ] && ok "a --prompt run is not sent to Jev" || bad "prompt run made $(reqs) request(s)"
out=$(ORCHESTRA_JEV=advise ORCHESTRA_JEV_KEY_CMD=false "$W" run H4 --spec spec.md 2>&1); rc=$?
[ "$rc" = 0 ] && ok "advise with a broken Jev still runs the task (exit 0)" || { bad "run with broken jev: rc $rc"; echo "$out"; }

# ---- doctor, mark, report ----------------------------------------------------------------------------------------
out=$(ORCHESTRA_JEV=advise "$W" doctor 2>&1 || true); has "$out" "jev: advise, model typesafe/jev" && ok "doctor reports the mode and model" || bad "doctor on"
out=$(ORCHESTRA_JEV=advise ORCHESTRA_JEV_KEY_CMD="" "$W" doctor 2>&1 || true); has "$out" "ORCHESTRA_JEV_KEY_CMD is not set" && ok "doctor warns about a missing key command" || bad "doctor key"
rm -f "$LOG"; scenario "$(choice route worker=0.9 split=0.05 orchestrator=0.05)"
"$W" decide split A1 --spec spec.md >/dev/null 2>&1            # Jev: worker; the spec says worker -> agree
scenario "$(choice route worker=0.2 split=0.7 orchestrator=0.1)"
"$W" decide split A2 --spec spec.md >/dev/null 2>&1            # Jev: split; the spec says worker -> differ
"$W" decide mark A2 split worker
out=$("$W" decide report 2>&1)
has "$out" "split: 2 decision(s), 1 agree, 1 disagree" && has "$out" "differ  A2 split: jev split, you worker" && ok "report compares Jev with the spec's and your calls" || { bad "report"; echo "$out"; }
out=$("$W" decide report --json 2>&1)
python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["kinds"]["split"]["disagree"]==1' <<<"$out" && ok "report --json" || bad "report --json"
out=$("$W" decide mark A2 2>&1); rc=$?; [ "$rc" = 2 ] && ok "mark needs task, kind and value" || bad "mark usage rc $rc"

echo "decide: $pass passed, $fail failed"
[ "$fail" = 0 ]
