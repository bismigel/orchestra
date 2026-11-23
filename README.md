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
  or push. Its API key arrives on a file descriptor, never on a command line or on disk. Optionally
  (`ORCHESTRA_EGRESS_ALLOW`) it can reach only the hosts you list.
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
./install.sh                         # links the `orchestra-worker` command into ~/.local/bin and the Claude Code skill
$EDITOR ~/.config/orchestra/config.env   # pick the worker model and how to fetch its API key
tests/all.sh                         # offline self-tests (no model calls)
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

- **`scout`**: before a spec is final, `orchestra-worker scout <id> --spec draft.md` sends a read-only worker to
  check it against the code (real paths, missed files and tests, broken commands, size) and prints a block to paste
  into the spec. Cents per task; you keep the decisions.

## Ops profile (infrastructure)
`ORCHESTRA_PROFILE=ops` in a repository's `.orchestra/config.env` is for GitOps infrastructure work: workers get a
stricter prompt (no credentials, validators, rendered-diff report), tasks need `risk` and `rollback`, and two skills
cover it: `ops-change` (one loop for every change, with checklists for new apps, upgrades, backups and secret
rotation) and `ops-incident`. They are installed only with `./install.sh --ops`. See
[docs/ops-guide.md](docs/ops-guide.md).

## How you use it
1. **Classify** the task: `worker` (spec settles everything), `split` (you write the risky rules and test rows
   first), or `orchestrator` (do it yourself). Never delegate judgment calls.
2. **Write the spec**: goal, allowed paths, decisions, acceptance the worker can run, out of scope.
3. **Launch**: `orchestra-worker run <id> --spec spec.md`. Run it in the background; 2-3 workers at a time.
4. **Review**: `orchestra-worker review <id>` puts it on one screen: how the run ended, **blocking** questions,
   **assumed** calls, files changed outside the spec's paths, the worker's claimed checks, proofs for the exact
   code, and a ranked diff stat (`--json` for editor widgets). Then the diff, your own run of the checks, and probes with your own inputs.
5. **Feedback** (`--feedback review.md`, same session), or prove and land: `orchestra-worker diff <id>` (no
   generated noise), `orchestra-worker prove <id>`, `orchestra-worker land <id>`. A worker's report is a claim; a
   proof is a check orchestra ran itself on the exact code ([docs/proofs.md](docs/proofs.md)).
   `orchestra-worker clean` then lists worktrees of landed tasks; `--yes` removes them.

Beyond the loop: `orchestra-worker history` lists every task's runs, cost and outcome (cleaned-up worktrees
included); `orchestra-worker lessons <id>` drafts lessons-file lines from the spec gaps a review found;
`orchestra-worker guide <name>` prints a guide's path (`--print` prints its text, and
`orchestra-worker guide templates` prints the template directory). `orchestra-worker doctor` is the setup check
(sandbox, harness, key, model, base, gate; not implemented yet).

## Seeing what is happening
```
$ orchestra-worker status
TASK     STATE    ELAPSED  RUN  TOOLS    COST  NOW
T41      running  6m12s    1       38  $0.041  edit internal/web/layout.templ
T44      running  2m03s    1       11  $0.012  quiet 2m10s · bash go test ./internal/web/ -run Notice
T39      stale    1h02m    1        -       -  process gone
```
- **While a run works**, its output has one line per tool call (`T41 03:12 #14 edit internal/web/layout.templ`)
  and a `quiet for` line after a minute without one, so a background run's log reads like a progress feed.
- **`orchestra-worker watch`** redraws that table every two seconds with each worker's last actions. Keep it open
  in a terminal next to your agent.
- **When a run ends** it prints a card: exit meaning, time, cost, blocking questions first, then the next command.
- **stale** means the process is gone: never wait on a stale run. `--json` feeds editor widgets
  ([examples/pi/workers.ts](examples/pi/workers.ts) shows each worker's current action in pi).

The full loop is in [docs/orchestrator-guide.md](docs/orchestrator-guide.md); the reasoning in
[docs/design.md](docs/design.md); the threat model and known gaps in [docs/security.md](docs/security.md).

### Make it the default in Claude Code
`install.sh` installs the skill (`/orchestra`). To have every session use it, add one line to `~/.claude/CLAUDE.md`:
```
- Delegate mechanical coding work with the orchestra skill: I decide and review; workers only implement settled specs.
```
Other orchestrators: reference `docs/orchestrator-guide.md` from their `AGENTS.md`.

## Status
Early and evolving: the interface (`run`, `summary`, `status`, `review`, `diff`, `prove`, `land`, the report schema, the config keys) is meant to stay stable
while the inside improves. Planned: more harness adapters, macOS
sandboxing, and an optional long-running worker service for unattended queues. Ideas and adapters are welcome.

## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md). Run `tests/all.sh` before opening a pull request.

## License
[MIT](LICENSE)
