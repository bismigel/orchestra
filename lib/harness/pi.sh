# shellcheck shell=bash
# Harness adapter: pi (https://github.com/earendil-works/pi), headless JSON mode.
# A harness provides three functions; see docs/adding-a-harness.md.
#   harness_argv <array-name> <task> <state-dir> <prompt>   build the command that runs one worker turn
#   harness_models_used <events-file>                       print "provider/model" for every model that answered
#   harness_usage <events-file>                             print {"responses","input","output","cost"} as JSON
# pi reads AGENTS.md / CLAUDE.md from the working directory by itself, so the repository's rules reach the worker.

harness_argv() {
  local -n _argv=$1; local task=$2 state=$3 prompt=$4
  command -v pi >/dev/null || die "pi not found on PATH (npm install -g @earendil-works/pi or your package manager)"
  local pi_bin; pi_bin=$(readlink -f "$(command -v pi)")
  _argv=("$pi_bin" -p --mode json
    --model "$ORCHESTRA_MODEL" --models "$ORCHESTRA_MODEL" --thinking "$ORCHESTRA_THINKING"
    --session-id "$task" --session-dir "$state/sessions" --name "orchestra worker $task"
    --no-mcp --no-extensions --no-skills --no-prompt-templates --no-approve
    "$prompt")
}

harness_models_used() {
  python3 -I - "$1" <<'PY'
import json, sys
seen = set()
for line in open(sys.argv[1], errors="replace"):
    try: e = json.loads(line)
    except ValueError: continue
    m = e.get("message")
    if e.get("type") == "message_end" and isinstance(m, dict) and m.get("role") == "assistant" and m.get("model"):
        seen.add(f'{m.get("provider", "?")}/{m["model"]}')
print(" ".join(sorted(seen)))
PY
}

harness_usage() {
  python3 -I - "$1" <<'PY'
import json, sys
t = {"responses": 0, "input": 0, "output": 0, "cache_read": 0, "reasoning": 0, "cost": 0.0}
for line in open(sys.argv[1], errors="replace"):
    try: e = json.loads(line)
    except ValueError: continue
    m = e.get("message")
    if e.get("type") != "message_end" or not isinstance(m, dict) or m.get("role") != "assistant": continue
    u = m.get("usage") or {}
    t["responses"] += 1
    t["input"] += u.get("input", 0) or 0
    t["output"] += u.get("output", 0) or 0
    t["cache_read"] += u.get("cacheRead", 0) or 0
    t["reasoning"] += u.get("reasoning", 0) or 0
    t["cost"] += (u.get("cost") or {}).get("total", 0) or 0
print(json.dumps(t))
PY
}
