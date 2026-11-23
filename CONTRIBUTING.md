# Contributing

Thanks for helping. orchestra is small on purpose: a launcher script, harness adapters, prompts and docs.

## Good first contributions
- A harness adapter (`lib/harness/<name>.sh`, see `docs/adding-a-harness.md`) with a fixture test.
- An orchestrator adapter: instructions or a skill for another agent, next to `skills/claude-code/`.
- Sandbox work from `docs/security.md` "Known gaps": egress allowlisting, resource limits, macOS.
- Real-world reports: what a task cost, how many rounds, what review caught. Open an issue; they shape the guide.

## Rules
- `tests/all.sh` (every suite in `tests/`) must pass, offline and without a model key (use or extend the fake harness).
- `shellcheck -S warning` must be clean.
- Keep the stable interface stable: `orchestra-worker run|summary`, the exit codes, `schemas/report.schema.json` and
  the `ORCHESTRA_*` config keys. If one must change, say so in the pull request and in `CHANGELOG.md`.
- Never weaken the sandbox or key handling to make something work; document the gap instead.
- No real secrets, personal data or private hostnames in examples, fixtures or issues.
