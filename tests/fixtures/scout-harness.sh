# shellcheck shell=bash
# Test harness for the scout: tries to write the repository, its git directory and a commit (all must fail), then
# writes a minimal scout.json to its home. No model, no network. SCOUT_STATE=1 also writes state.md and drift.
harness_argv() {
  local -n _argv=$1; local task=$2
  _argv=(bash -c '
    touch PROBE-repo 2>/dev/null && echo "WROTE-REPO" >&2 || echo "repo-readonly" >&2
    touch .git/PROBE-git 2>/dev/null && echo "WROTE-GIT" >&2 || echo "git-readonly" >&2
    git commit --allow-empty -qm evil 2>/dev/null && echo "COMMITTED" >&2 || echo "commit-refused" >&2
    printf "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"provider\":\"fake\",\"model\":\"worker-1\",\"usage\":{\"cost\":{\"total\":0.001}}}}\n"
    drift=""
    if [ "$2" = 1 ]; then
      printf "# Live state\n\n## Drift\n- live replicas 2, git replicas 1\n" > ~/state.md
      drift=",\"drift\":[\"live replicas 2, git replicas 1\"]"
    fi
    printf "{\"task\":\"%s\"%s,\"named\":[{\"spec_says\":\"x.go\",\"found\":false,\"actual\":\"y.go:3\"}],\"files_to_change\":[{\"path\":\"y.go\",\"why\":\"wiring\",\"in_spec\":false}],\"size\":{\"files\":1,\"lines\":10,\"split\":\"\"}}" "${1#scout-}" "$drift" > ~/scout.json
  ' fake "$task" "${SCOUT_STATE:-0}")
}
harness_models_used() { echo fake/worker-1; }
harness_usage() { echo '{"responses":1,"cost":0.001}'; }
