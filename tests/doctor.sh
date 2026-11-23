#!/usr/bin/env bash
# doctor: reports the setup without ever printing the API key, and fails on what would break a run. Offline.
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W="$ROOT/bin/orchestra-worker"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
git init -q -b main "$TMP/repo" && git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
export XDG_CONFIG_HOME="$TMP/cfg" ORCHESTRA_HARNESS="$ROOT/tests/fixtures/fake-harness.sh" ORCHESTRA_BASE=main
export ORCHESTRA_KEY_ENV=FAKE_API_KEY ORCHESTRA_GATE=true
SECRET="sk-doctor-$RANDOM$RANDOM$RANDOM"
doc() { ( cd "$TMP/repo" && env "$@" "$W" doctor ) > "$TMP/out" 2>&1; echo $?; }

rc=$(doc ORCHESTRA_MODEL=fake/worker-1 FAKE_SECRET="$SECRET" ORCHESTRA_KEY_CMD='printf %s "$FAKE_SECRET"' ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1)
[ "$rc" = 0 ] && ok "a working setup passes" || { bad "working setup: rc $rc"; sed 's/^/     /' "$TMP/out"; }
grep -qF "$SECRET" "$TMP/out" && bad "THE KEY WAS PRINTED" || ok "the key is never printed"
fp=$(printf %s "$SECRET" | sha256sum | cut -c1-8)
grep -q "${#SECRET} characters, fingerprint $fp" "$TMP/out" && ok "key reported by length and fingerprint" || bad "no key fingerprint line"
grep -q "warn  ORCHESTRA_SANDBOX=none" "$TMP/out" && ok "unsandboxed mode is a warning" || bad "unsandboxed not warned"

rc=$(doc ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_KEY_CMD='exit 1' ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1)
[ "$rc" = 1 ] && grep -q "FAIL  no key from ORCHESTRA_KEY_CMD" "$TMP/out" && ok "a failing key command fails" || bad "failing key command: rc $rc"
rc=$(doc ORCHESTRA_MODEL= ORCHESTRA_KEY_ENV= ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1)
[ "$rc" = 1 ] && grep -q "FAIL  ORCHESTRA_MODEL is not set" "$TMP/out" && ok "a missing model fails" || bad "missing model: rc $rc"
rc=$(doc ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_ALLOWED_MODELS=other/m ORCHESTRA_KEY_ENV= ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1)
[ "$rc" = 1 ] && grep -q "not in ORCHESTRA_ALLOWED_MODELS" "$TMP/out" && ok "a model outside the allowlist fails" || bad "allowlist: rc $rc"
rc=$(doc ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_KEY_ENV= ORCHESTRA_SANDBOX=none)
[ "$rc" = 1 ] && grep -q "without ORCHESTRA_ALLOW_UNSANDBOXED" "$TMP/out" && ok "sandbox none without the opt-in fails" || bad "sandbox none: rc $rc"
rc=$(doc ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_KEY_ENV= ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1 ORCHESTRA_MAX_COST=lots)
[ "$rc" = 1 ] && grep -q "ORCHESTRA_MAX_COST must be a number" "$TMP/out" && ok "a malformed budget fails" || bad "budget: rc $rc"
rc=$(doc ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_KEY_ENV= ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1 ORCHESTRA_EGRESS_ALLOW='http://x')
[ "$rc" = 1 ] && grep -q "egress allowlist is malformed" "$TMP/out" && ok "a malformed allowlist fails" || bad "egress: rc $rc"
rc=$(doc ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_KEY_ENV= ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1 ORCHESTRA_BASE=origin/nowhere)
[ "$rc" = 1 ] && grep -q "base origin/nowhere does not resolve" "$TMP/out" && ok "an unresolvable base fails" || bad "base: rc $rc"
rc=$(doc ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_KEY_ENV= ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1 ORCHESTRA_GATE=)
[ "$rc" = 0 ] && grep -q "warn  no ORCHESTRA_GATE" "$TMP/out" && ok "no gate is a warning, not a failure" || bad "no gate: rc $rc"
rc=$(doc ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_KEY_ENV= ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1 ORCHESTRA_DEVENV_CMD=false)
[ "$rc" = 1 ] && grep -q "ORCHESTRA_DEVENV_CMD failed" "$TMP/out" && ok "a failing dev environment fails" || bad "devenv: rc $rc"
echo "doctor: $pass passed, $fail failed"
[ "$fail" = 0 ]
