# shellcheck shell=bash
# Test harness for the scout: tries to write the repository, its git directory and a commit (all must fail), then
# writes a minimal scout.json to its home. No model, no network.
harness_argv() {
  local -n _argv=$1; local task=$2
  _argv=(bash -c '
    touch PROBE-repo 2>/dev/null && echo "WROTE-REPO" >&2 || echo "repo-readonly" >&2
    touch .git/PROBE-git 2>/dev/null && echo "WROTE-GIT" >&2 || echo "git-readonly" >&2
    git commit --allow-empty -qm evil 2>/dev/null && echo "COMMITTED" >&2 || echo "commit-refused" >&2
    printf "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"provider\":\"fake\",\"model\":\"worker-1\",\"usage\":{\"cost\":{\"total\":0.001}}}}\n"
    printf "{\"task\":\"%s\",\"named\":[{\"spec_says\":\"x.go\",\"found\":false,\"actual\":\"y.go:3\"}],\"files_to_change\":[{\"path\":\"y.go\",\"why\":\"wiring\",\"in_spec\":false}],\"size\":{\"files\":1,\"lines\":10,\"split\":\"\"}}" "${1#scout-}" > ~/scout.json
  ' fake "$task")
}
harness_models_used() { echo fake/worker-1; }
harness_usage() { echo '{"responses":1,"cost":0.001}'; }
