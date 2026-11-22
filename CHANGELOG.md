# Changelog

## 0.1.1 (2026-11-22)
- `--dry-run` has no side effects: it no longer runs `ORCHESTRA_WORKTREE_CMD` or creates state for a new task; it
  prints the sandbox plan with the paths it would use.
- Offline suite: 41 checks.

## 0.1.0 (2026-11-22)
First public version, extracted from a production pilot.
- `orchestra-worker run|summary`; exit codes 0/2/3/4/124.
- pi harness adapter; harness may also be a path to a custom adapter.
- Model allowlist enforced from the event log; per-run and per-task cost.
- bubblewrap sandbox: worktree read-write, shared git objects read-only, cleared environment, PATH derived from
  yours; API key on a file descriptor; harness stdin closed.
- Specs outside the worktree are copied in; reports validated against the schema's required fields.
- Orchestrator guide, design notes, security model, Claude Code skill, installer, offline test suite (39 checks).
