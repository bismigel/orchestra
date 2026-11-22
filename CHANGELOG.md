# Changelog

## 0.2.0 (2026-11-22)
- **Planning**: `orchestra-plan` and `orchestra-refine` skills, `docs/planning-guide.md`, templates (brief, scope,
  decisions, architecture, task, wireframe, lessons). Proposal 0001.
- **`orchestra-task lint`**: the mechanical half of the definition of ready (front matter, ownership overlaps unless
  chained, paths on the base branch with shorthand resolution, runnable acceptance, dependencies, out of scope).
- **Ops profile** (`ORCHESTRA_PROFILE=ops`): `prompts/worker-ops.md`, `risk`/`rollback` task fields, `docs/ops-guide.md`
  and eight `ops-*` skills. Proposal 0002.
- `install.sh` links every skill and `orchestra-task`. Offline suite: 63 checks.

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
