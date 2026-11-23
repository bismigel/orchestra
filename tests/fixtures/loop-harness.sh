# shellcheck shell=bash
# Test harness that never stops on its own: one pi-style response costing $0.01 every 0.2 s, until killed.
# It records its pid so a test can check the sandboxed process really died.
harness_argv() {
  local -n _argv=$1
  _argv=(bash -c 'echo $$ > .orchestra/loop.pid
    while :; do
      printf "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"provider\":\"fake\",\"model\":\"worker-1\",\"usage\":{\"cost\":{\"total\":0.01}}}}\n"
      sleep 0.2
    done')
}
harness_models_used() { echo fake/worker-1; }
harness_usage() { (. "$ORCHESTRA_TEST_ROOT/lib/harness/pi.sh"; harness_usage "$1"); }
