# shellcheck shell=bash
# Test harness: no model, no network. Emits one pi-style event naming $FAKE_MODEL and writes a report
# (FAKE_REPORT=valid|invalid|none). Settings are baked into the command because the sandbox clears the environment.
# It also reports whether the API key arrived (without printing it) and whether the key is visible in any process's
# command line inside the sandbox (it must not be).
harness_argv() {
  local -n _argv=$1; local task=$2
  _argv=(bash -c '
    task=$1 model=$2 report=$3 keyvar=$4 want=$5    # want = sha256 of the expected key; the key itself is never an argument
    secret=${!keyvar:-}
    printf "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"provider\":\"%s\",\"model\":\"%s\",\"usage\":{\"input\":10,\"output\":5,\"cost\":{\"total\":0.001}}}}\n" "${model%%/*}" "${model#*/}"
    if [ -n "$secret" ] && [ "$(printf %s "$secret" | sha256sum | cut -d" " -f1)" = "$want" ]; then echo "fake: key-present" >&2; fi
    if [ -n "$secret" ]; then for f in /proc/[0-9]*/cmdline; do if grep -qa -- "$secret" "$f" 2>/dev/null; then echo "fake: KEY-IN-CMDLINE $f" >&2; fi; done; fi
    for t in python3 git; do command -v "$t" >/dev/null && echo "fake: tool-$t-ok" >&2; done
    case "$report" in
      valid) printf "{\"task\":\"%s\",\"status\":\"done\",\"summary\":\"ok\",\"files_changed\":[],\"checks\":[],\"open_questions\":[]}" "$task" > .orchestra/report.json ;;
      invalid) echo "{not json" > .orchestra/report.json ;;
    esac
    # FAKE_END=1: announce the end, then linger, so the progress follower exits before the run does (a race that
    # once aborted runs under set -e).
    if [ "$6" = 1 ]; then echo "{\"type\":\"agent_end\"}"; sleep 2; fi' fake "$task" "${FAKE_MODEL:?}" "${FAKE_REPORT:-valid}" "${ORCHESTRA_KEY_ENV:-}" "$(printf %s "${FAKE_SECRET:-}" | sha256sum | cut -d" " -f1)" "${FAKE_END:-0}")
}
# Event parsing is the real pi adapter's, so these tests cover it too.
harness_models_used() { (. "$ORCHESTRA_TEST_ROOT/lib/harness/pi.sh"; harness_models_used "$1"); }
harness_usage() { (. "$ORCHESTRA_TEST_ROOT/lib/harness/pi.sh"; harness_usage "$1"); }
