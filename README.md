# orchestra

**A strong model decides. Cheap models type.**

orchestra lets an orchestrating agent (Claude Code, Codex, opencode, or you) hand well-specified coding tasks to
cheap, fast worker models running in a sandbox, then review what they did before anything lands. The orchestrator
keeps every judgment call (design, data rules, edge cases, the tests that pin them); workers implement the settled
remainder and report back.

- **Model-agnostic workers**: any provider and model your harness supports (DeepSeek, OpenAI, Anthropic, Qwen via
  OpenRouter, local Ollama, …). One model per run, enforced from the event log.
- **Harness-pluggable**: [pi](https://github.com/earendil-works/pi) today; adding another is three bash functions.
- **Orchestrator-agnostic**: a plain-markdown [orchestrator guide](docs/orchestrator-guide.md) any agent can follow,
  plus a ready [Claude Code skill](skills/claude-code/orchestra/SKILL.md).
- **Sandboxed** (bubblewrap): a worker sees its own git worktree and nothing else from your home. It cannot commit
  or push. Its API key arrives on a file descriptor, never on a command line or on disk.
- **Costs cents**: per-run tokens and cost are summed from the harness's own log.

```
you ── orchestrator (strong model) ── decides, writes the spec, reviews, merges
                │  orchestra-worker run <task> --spec spec.md
                ▼
        worker (cheap model, sandboxed, own worktree) ── implements, runs checks, writes a report
                │  exit code + .orchestra/report.json + cost
                ▼
        orchestrator ── reads the diff, runs the checks itself, probes risky paths ── feedback or land
```

## Real numbers
The first production task was privacy-sensitive (redaction rules plus 40 table-driven tests). Two worker rounds on
DeepSeek Flash cost **$0.15**. The orchestrator's review caught two privacy bugs the worker's own tests missed; they
went back as required test cases and were fixed in round two. That review step is the point of the design.

## Quick start
Requirements: Linux with [bubblewrap](https://github.com/containers/bubblewrap), `git`, `python3`, coreutils
`timeout`, and a harness ([pi](https://github.com/earendil-works/pi)).

```sh
git clone https://github.com/bismigel/orchestra && cd orchestra
./install.sh                         # links orchestra-worker into ~/.local/bin and the Claude Code skill
$EDITOR ~/.config/orchestra/config.env   # pick the worker model and how to fetch its API key
tests/run.sh                         # offline self-test (no model calls)
```

Minimal config (`~/.config/orchestra/config.env`):
```sh
ORCHESTRA_MODEL=deepseek/deepseek-flash
ORCHESTRA_ALLOWED_MODELS=deepseek/deepseek-flash
ORCHESTRA_KEY_ENV=DEEPSEEK_API_KEY
ORCHESTRA_KEY_CMD='pass show api/deepseek-workers'   # any command that prints the key
```
See [config/config.example.env](config/config.example.env) for other providers, local models, dev environments
(`nix print-dev-env`, `mise`), cache mounts and per-repository settings.

Try it on the bundled example (cost: well under one cent):
```sh
cd your-repo
orchestra-worker run hello --spec /path/to/orchestra/examples/hello/spec.md
orchestra-worker summary hello
```

## Planning and refinement
Workers do better work from better specs, so orchestra also helps you write them:
- **`plan`** (skill `orchestra-plan`): a planning session for a new project: brief, numbered decisions, scope and
  MVP line, architecture, HTML wireframes, and a board of worker-ready tasks. Checkpoints you approve; the planning
  pack in the repository is the state. See [docs/planning-guide.md](docs/planning-guide.md) and
  [templates/](templates/).
- **`refine`** (skill `orchestra-refine`): brings tasks up to the definition of ready. Its mechanical half is a CLI:
  ```sh
  orchestra-task lint            # every open task in docs/work/tasks (front matter, ownership overlaps, paths,
                                 # runnable acceptance, dependencies, out of scope)
  ```

## Ops profile (infrastructure)
`ORCHESTRA_PROFILE=ops` in a repository's `.orchestra/config.env` is for GitOps infrastructure work: workers get a
stricter prompt (no credentials, validators, rendered-diff report), tasks need `risk` and `rollback`, and eight
skills cover the change loop, preflight, review, incidents, new apps, upgrades, secret rotation and backup drills.
See [docs/ops-guide.md](docs/ops-guide.md).

## How you use it
1. **Classify** the task: `worker` (spec settles everything), `split` (you write the risky rules and test rows
   first), or `orchestrator` (do it yourself). Never delegate judgment calls.
2. **Write the spec**: goal, allowed paths, decisions, acceptance the worker can run, out of scope.
3. **Launch**: `orchestra-worker run <id> --spec spec.md`. Run it in the background; 2-3 workers at a time.
4. **Review**: exit code (`3` = a disallowed model answered, `4` = no valid report), the report's open questions,
   the diff, your own run of the checks, and probes with your own inputs.
5. **Feedback** (`--feedback review.md`, same session) or **land** it yourself: workers cannot commit.

The full loop is in [docs/orchestrator-guide.md](docs/orchestrator-guide.md); the reasoning in
[docs/design.md](docs/design.md); the threat model and known gaps in [docs/security.md](docs/security.md).

### Make it the default in Claude Code
`install.sh` installs the skill (`/orchestra`). To have every session use it, add one line to `~/.claude/CLAUDE.md`:
```
- Delegate mechanical coding work with the orchestra skill: I decide and review; workers only implement settled specs.
```
Other orchestrators: reference `docs/orchestrator-guide.md` from their `AGENTS.md`.

## Status
Early and evolving: the interface (`run`, `summary`, the report schema, the config keys) is meant to stay stable
while the inside improves. Planned: an egress-allowlisting proxy (issue #2) for the sandbox, more harness adapters, macOS
sandboxing, and an optional long-running worker service for unattended queues. Ideas and adapters are welcome.

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md). Run `tests/run.sh` before opening a pull request.

## License
[MIT](LICENSE)
