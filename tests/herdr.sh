#!/usr/bin/env bash
# herdr: inside a herdr pane a run opens a watch pane and ends with a notification; outside a pane, with
# ORCHESTRA_HERDR=off, or with herdr failing, the run's own output and exit code are unchanged. Offline: a fake
# herdr and a fake harness.
set -uo pipefail
main() {
  # Isolate from any outer orchestra-worker invocation.
  local _v
  for _v in $(compgen -e | grep '^ORCHESTRA_' || true); do unset "$_v"; done
  for _v in $(compgen -e | grep '^HERDR_' || true); do unset "$_v"; done
  local root; root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
  local W="$root/bin/orchestra-worker" pass=0 fail=0
  export ORCHESTRA_TEST_ROOT=$root
  TMP_DIR=$(mktemp -d); trap 'rm -rf "$TMP_DIR"' EXIT
  local tmp=$TMP_DIR
  export XDG_CONFIG_HOME="$tmp/cfg"        # never read the developer's own config

  ok()  { pass=$((pass+1)); echo "ok   $*"; }
  bad() { fail=$((fail+1)); echo "FAIL $*"; }
  expect_rc() { local want=$1 name=$2; shift 2; local rc=0; "$@" >"$tmp/out" 2>&1 || rc=$?
    if [ "$rc" = "$want" ]; then ok "$name (rc $rc)"; else bad "$name: rc $rc, want $want"; sed 's/^/     /' "$tmp/out"; fi; }
  has() { if grep -q -- "$2" "$tmp/out"; then ok "$1"; else bad "$1: output lacks '$2'"; sed 's/^/     /' "$tmp/out"; fi; }
  log_has() { if grep -q -- "$2" "$HERDR_LOG" 2>/dev/null; then ok "$1"; else bad "$1: herdr log lacks '$2'"; sed 's/^/     /' "$HERDR_LOG" 2>/dev/null; fi; }
  log_lacks() { if grep -q -- "$2" "$HERDR_LOG" 2>/dev/null; then bad "$1: herdr log has '$2'"; sed 's/^/     /' "$HERDR_LOG"; else ok "$1"; fi; }

  # A throwaway repository with one commit, and a spec for the scout.
  local repo="$tmp/demo"; git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  cp "$root/examples/hello/spec.md" "$repo/spec.md"

  # A fake herdr on PATH: it appends its arguments to $HERDR_LOG; pane split prints a pane id. FAKE_HERDR_FAIL=1
  # makes every call fail after logging, to prove a broken herdr cannot break a run.
  local hbin="$tmp/herdrbin"; mkdir -p "$hbin"
  cat > "$hbin/herdr" <<'HERDR'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_LOG"
if [ "${FAKE_HERDR_FAIL:-0}" = 1 ]; then echo "not json{"; exit 1; fi
if [ "${1:-}" = pane ] && [ "${2:-}" = split ]; then printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p9"}}}'
else printf '%s\n' '{"result":"HERDR-LEAK"}'; echo "HERDR-LEAK on stderr" >&2; fi
exit 0
HERDR
  chmod +x "$hbin/herdr"
  export HERDR_LOG="$tmp/herdr.log" PATH="$hbin:$PATH"

  export FAKE_MODEL=fake/worker-1
  export ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_ALLOWED_MODELS=fake/worker-1
  export ORCHESTRA_HARNESS="$root/tests/fixtures/fake-harness.sh" ORCHESTRA_KEY_ENV=FAKE_API_KEY
  export FAKE_SECRET="sk-herdr-$RANDOM$RANDOM" ORCHESTRA_KEY_CMD='printf %s "$FAKE_SECRET"' ORCHESTRA_TIMEOUT=60s
  export ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1 ORCHESTRA_BASE=main

  # 1. Inside a herdr pane with the default config: a watch pane and a notification.
  rm -f "$HERDR_LOG"
  expect_rc 0 "run inside herdr exits 0" env -C "$repo" HERDR_ENV=1 "$W" run T1 --prompt x
  log_has "a split pane was opened below, unfocused" 'pane split --current --direction down.*--no-focus'
  log_has "the pane runs watch for the task and exits" 'pane run w1:p9 .*watch T1; exit'
  log_has "the run ends with a done notification" 'notification show .*orchestra run T1: exit 0.*--sound done'
  local n; n=$(grep -c 'notification show' "$HERDR_LOG" 2>/dev/null || true)
  [ "$n" = 1 ] && ok "exactly one notification per run" || bad "notifications: $n, want 1"
  if grep -q HERDR-LEAK "$tmp/out"; then bad "herdr output leaked into orchestra-worker's output"; else ok "herdr output never reaches orchestra-worker's output"; fi

  # 2. No HERDR_ENV: nothing changes.
  rm -f "$HERDR_LOG"
  expect_rc 0 "run outside herdr exits 0" env -C "$repo" -u HERDR_ENV "$W" run T2 --prompt x
  [ ! -s "$HERDR_LOG" ] && ok "no herdr calls outside a herdr pane" || { bad "herdr was called outside a pane"; sed 's/^/     /' "$HERDR_LOG"; }

  # 3. ORCHESTRA_HERDR=off: nothing.
  rm -f "$HERDR_LOG"
  expect_rc 0 "run with ORCHESTRA_HERDR=off exits 0" env -C "$repo" HERDR_ENV=1 ORCHESTRA_HERDR=off "$W" run T3 --prompt x
  [ ! -s "$HERDR_LOG" ] && ok "off makes no herdr call" || { bad "off still called herdr"; sed 's/^/     /' "$HERDR_LOG"; }

  # 4. notify: the notification, no pane.
  rm -f "$HERDR_LOG"
  expect_rc 0 "run with ORCHESTRA_HERDR=notify exits 0" env -C "$repo" HERDR_ENV=1 ORCHESTRA_HERDR=notify "$W" run T4 --prompt x
  log_has "notify still shows the notification" 'notification show .*orchestra run T4: exit 0'
  log_lacks "notify opens no pane" '^pane '

  # 5. A failing herdr never breaks the run or hides its end card.
  rm -f "$HERDR_LOG"
  expect_rc 0 "a failing herdr still exits 0" env -C "$repo" HERDR_ENV=1 FAKE_HERDR_FAIL=1 "$W" run T5 --prompt x
  has "the end card is still printed" '── T5 · run 1 exit 0'

  # 6. A run that ends non-zero notifies with the exit and the request sound.
  rm -f "$HERDR_LOG"
  expect_rc 4 "a run with no report exits 4" env -C "$repo" HERDR_ENV=1 FAKE_REPORT=none "$W" run T6 --prompt x
  log_has "the failure is notified with its exit" 'notification show .*orchestra run T6: exit 4.*--sound request'

  # 7. A bad ORCHESTRA_HERDR is a config error (even on a dry run).
  expect_rc 2 "a bogus ORCHESTRA_HERDR is refused" env -C "$repo" HERDR_ENV=1 ORCHESTRA_HERDR=bogus "$W" run T7 --prompt x --dry-run
  has "the error names the valid values" 'ORCHESTRA_HERDR must be auto, notify or off'

  # 8. A dry run makes no herdr call.
  rm -f "$HERDR_LOG"
  expect_rc 0 "dry run inside herdr exits 0" env -C "$repo" HERDR_ENV=1 "$W" run T8 --prompt x --dry-run
  [ ! -s "$HERDR_LOG" ] && ok "dry run makes no herdr call" || { bad "dry run called herdr"; sed 's/^/     /' "$HERDR_LOG"; }

  # 9. A scout gets the same watch pane and notification.
  rm -f "$HERDR_LOG"
  expect_rc 0 "scout inside herdr exits 0" env -C "$repo" HERDR_ENV=1 ORCHESTRA_HARNESS="$root/tests/fixtures/scout-harness.sh" "$W" scout S1 --spec spec.md
  log_has "the scout pane runs watch for the task" 'pane run w1:p9 .*watch S1; exit'
  log_has "the scout ends with its notification" 'notification show .*orchestra scout S1: exit 0'

  # 10. doctor says whether this is a herdr pane.
  expect_rc 0 "doctor inside herdr exits 0" env -C "$repo" HERDR_ENV=1 "$W" doctor
  has "doctor reports the herdr pane" 'herdr: in a herdr pane (ORCHESTRA_HERDR=auto)'
  expect_rc 0 "doctor outside herdr exits 0" env -C "$repo" -u HERDR_ENV "$W" doctor
  has "doctor says herdr is optional" 'herdr: not in a herdr pane (optional)'

  echo "herdr: $pass passed, $fail failed"
  [ "$fail" = 0 ]
}

main "$@"
