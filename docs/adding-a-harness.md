# Adding a harness

A harness is the agent program a worker runs in (pi today). Supporting another one (opencode, aider, Codex CLI,
Claude Code headless, …) means adding `lib/harness/<name>.sh` with three bash functions, then setting
`ORCHESTRA_HARNESS=<name>`.

```bash
# Build the command for one worker turn. Fill the array named by $1.
# Requirements: non-interactive; uses $ORCHESTRA_MODEL only; resumes the same conversation for the same <task>
# (store it under <state-dir>, which lives in the worktree); writes machine-readable events to stdout.
harness_argv() { local -n _argv=$1; local task=$2 state=$3 prompt=$4; _argv=(...); }

# Print every model that produced a response in the run, as "provider/model", space-separated.
# This is how the model allowlist is enforced, so read it from the harness's own event log, not from config.
harness_models_used() { ...; }

# Print one JSON object: {"responses": n, "input": tokens, "output": tokens, "cost": usd} (extra keys are fine).
# If the harness does not report cost, report tokens and leave cost 0.
harness_usage() { ...; }
```

Inside these functions you may use `die "message"` and the `ORCHESTRA_*` variables (model, thinking, timeout).
The command runs inside the sandbox with the worktree as the working directory and the API key exported as
`$ORCHESTRA_KEY_ENV`.

Test it with `orchestra-worker run demo --spec examples/hello/spec.md --dry-run`, then a real run on the example task,
and add a fixture-based test of `harness_models_used` and `harness_usage` under `tests/`.

## Optional: live progress
Put a reader next to the adapter, `lib/harness/<name>_progress.py`, and `run`, `scout`, `status` and `watch` use it to
show what a worker is doing. It reads the event log only and offers three commands (see `pi_progress.py`):
- `follow <events> --task T --start EPOCH`: print one line per tool call as the log grows, a quiet line after a minute
  without one, and a done line on SIGTERM or when the run ends.
- `snapshot <events>`: one JSON object: `tool_calls`, `turns`, `responses`, `cost`, `last_action`, `last_activity`,
  `files_touched`.
- `tail <events> --lines N`: the last N tool calls.
Without one, everything works the same, minus the live lines.
