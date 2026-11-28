# Changelog

## 0.8.0 (unreleased)
- **Removed the `orchestra/auto` router** (`examples/pi/orchestra-router.ts`, `docs/router.md`, `tests/router.sh`)
and `ORCHESTRA_ROUTER_EXT`. On Claude Code and Antigravity it could only set the level once per user turn, on Claude
there is no `off` to save with, and its own benchmark showed a fixed `low` as cheap as routing for workers. Workers
run a real model at a fixed level (`ORCHESTRA_MODEL=deepseek/deepseek-flash`, `ORCHESTRA_THINKING=low`). A config
that still sets `ORCHESTRA_ROUTER_EXT` stops with a message saying what to change.
- **Pre-run lint and local worktrees** (#29). `run` lints a spec from the task board before it creates anything and
refuses on failure (`--skip-lint`); `scout` warns. `run --local-worktree` / `ORCHESTRA_WORKTREE_LOCAL=1` skip
`ORCHESTRA_WORKTREE_CMD`, so nothing is pushed before `land`.
- **Progressive disclosure.** `orchestra-worker guide --list`, `guide <name> --toc`, `guide <name> --section <n|text>`
and `--cat` print guides a piece at a time (pi: the `orchestra_guide` tool); the orchestra skill is now the loop
only, with pointers into the guides.
- **Direct-edit nudge (pi).** In a repository that uses orchestra, the pi extension appends one reminder when the
orchestrator has edited `ORCHESTRA_DIRECT_EDIT_WARN` (default 3) source files itself since the last worker run.
`orchestra-worker decide mark <id> split orchestrator` silences it; `0` turns it off.
- **Jev, an advisory second opinion** (`ORCHESTRA_JEV=off|shadow|advise`, off by default; [docs/jev.md](docs/jev.md)).
`orchestra-worker decide split|ready|triage` asks a classifier model (Jev on Cloudflare Workers AI, or any endpoint
speaking the same body) three typed questions from `config/decisions.json`: worker, split or orchestrator for a spec;
five yes/no readiness checks; clean, look or block for a finished run. `run --spec` asks `split` and `ready`, text
`review` asks `triage`. Jev can only ask for a closer look: `triage` has a deterministic floor from the review facts,
and a verdict below it is never shown. State is whitelisted, redacted and capped; the token comes from
`ORCHESTRA_JEV_KEY_CMD`, never a file, log or output; a failure is logged and never changes an exit code. Answers go
to `<git dir>/orchestra/decisions.jsonl`; `decide mark` records your call and `decide report` compares the two.
New: `lib/decide.py`, `config/decisions.json`, `tests/decide.sh`, `orchestra-worker guide jev`.
- **`prove` records a candidate snapshot** in `.orchestra/candidate.json`: task, run, base and the commit it resolved
to, the tree hash the proofs bound to, the spec and its blob hash, and the time. `review` shows a `candidate:` line,
and both `review` (text and `--json`) and `land` report `candidate drift` with a stat when the worktree changed since.
`land` still re-proves the tree it publishes and leaves a fresh candidate; writing the record never invalidates the
proof (`.orchestra/` is excluded from the tree hash). `review --json` gains `candidate` (null, or the record plus
`drift` and `drift_stat`). New offline suite: `tests/candidate.sh`.
- **`history` and the ledger keep tokens**: every run record gains `input`, `output`, `cache_read`, `reasoning` and
  `tokens` (input + output + cache reads), and every task and scout a `tokens` total, so `clean` archives them too.
  `history` adds a `TOKENS` column and a token total; rows archived before this show `-` and are counted as
  "without token data".
- **`land` onto a local base**: `ORCHESTRA_BASE` may name a local branch (an integration branch, or a forge you cannot
  reach). `land` skips the fetch, proves as usual, then moves the branch with a compare-and-swap (rebasing and
  proving again if it moved), fast-forwards a checkout of it only when that checkout is clean, and refuses `--pr`.
  `doctor` reports a local base as ok instead of warning "land needs one". Skills, the guide and pi's land tool and
  prompt describe it.
- **Skills:** a new `orchestra-land` skill for Claude Code (the pi `/land` prompt's steps, plus landing onto a base
  that is not on a remote), and the `orchestra` skill now tells the orchestrator about `candidate:` and
  `candidate drift:` in review and land.

## 0.7.0 (2026-11-23)
Why: [proposals/0004](docs/proposals/0004-skill-gaps.md).
- **Bug (0.6.0 and earlier): stopping `orchestra-worker` left the worker running** until its timeout. The worker is
  now a supervised background job; SIGTERM and SIGINT stop it and clean up (exit 130).
- **One run per task**: a run or scout on a task whose run is alive is refused (exit 2); stale state is cleared.
- **`ORCHESTRA_MAX_COST`**: stops a run whose responses cost more (exit 5, `OVER BUDGET` on the card).
- **`orchestra-worker doctor`**: checks config, model, harness, sandbox (and private network namespaces), the key
  (length and fingerprint only), base, gate, dev environment, binds, budget and stale state.
- **`clean` archives before it deletes**, to a ledger in the git directory; **`orchestra-worker history`** shows every
  task's runs, cost and outcome, cleaned-up ones included, with the project total.
- **`orchestra-worker lessons <id>`** drafts lessons-file lines from a run's spec gaps; `review` shows
  `lessons N spec gap(s)` and its JSON gains `spec_gaps`. **Lint** warns when a task has no `proof:` line
  (`--strict` fails on warnings).
- **`land --pr`** (`ORCHESTRA_LAND=pr`) for protected bases: push the proven commit to `orchestra/<task>` and open a
  pull request (`ORCHESTRA_PR_CMD`, default `gh`); placeholders expand as variables, so titles are data.
- **`orchestra-worker guide <name>`** prints a guide's real path; skills use it instead of relative paths.
  `tests/docs.sh` keeps docs and CLI in step.
- **pi**: `examples/pi/orchestra.ts` (scout, run, status, review, prove, land tools; the model gets the end card and
  the review digest, progress goes to the tool view) and `examples/pi/prompts/land.md`.
- `--help` prints the whole header. Offline suites: 15, 500+ checks.

## 0.6.0 (2026-11-23)
- **Egress allowlist** (`ORCHESTRA_EGRESS_ALLOW`, issue #2): the sandbox gets a private network (loopback only, no
  DNS) whose only way out is orchestra's proxy outside the sandbox, which allows `CONNECT` to listed hosts only and
  logs each attempt (`runs/run-N.egress.log`; the finish card counts them). Fails closed; needs bwrap. See
  [docs/security.md](docs/security.md). Verified with a real pi worker on DeepSeek.
- **Stale worktree check** (issue #1): before a first run, a worktree with no work is rebased onto the base, and one
  with work whose spec changed on the base is refused unless `--allow-stale`.
- Fix: a run whose worker ended quickly could abort before writing its usage, result and card (the progress
  follower had already exited; 0.5.0 only).
- `review`/`prove`: a spec `proof:` line that repeats the gate runs once.
- Offline suites: 9, 315 checks (`tests/egress.sh`, `tests/freshness.sh` new).

## 0.5.0 (2026-11-23)
Why: [proposals/0003](docs/proposals/0003-scout-review-progress.md) (evidence from 19 production runs).
- **`orchestra-worker scout <id> --spec <draft>`**: a read-only worker checks a draft spec against the code and
  reports real paths, files and tests the spec missed, patterns, broken commands and size, with a block to paste
  into Touches. The checkout and git are mounted read-only; its output is `<repo>-worktrees/.scout/<id>/scout.json`.
- **`orchestra-worker review <id>`**: one-screen digest of a run: exit meaning, blocking questions, assumptions,
  files outside the spec's Owns/Touches, worker checks, proofs for the exact tree, ranked diff stat. `--json`
  gives the same digest as one object for editor widgets.
- **Report**: optional `assumptions` (small calls the worker made); `open_questions` now means blocking only.
- **Live progress**: one line per tool call while a run works, a quiet line after a minute, a finish card with
  blocking questions first. `status` shows tool calls, cost so far and the current action; `watch` redraws it every
  2 s. Harnesses opt in with `lib/harness/<name>_progress.py` (pi has one). `ORCHESTRA_PROGRESS=0` turns it off.
- **`orchestra-worker clean [--yes] [--include-squashed]`**: removes worktrees of landed tasks (merged, rebased or
  cherry-picked); never dirty or running ones, never forced, never a branch.
- **Ops**: two skills (`ops-change`, `ops-incident`) instead of eight; `install.sh --ops` installs them, and every
  install removes dangling skill links left by deleted skills.
- Runs write `runs/run-N.result.json` (exit, seconds); `run.json` records the event log and progress reader.
- `tests/all.sh` runs every suite; CI now runs all of them (it ran only `tests/run.sh` before).

## 0.4.0 (2026-11-23)
- **`orchestra-worker status` (alias `ps`)**: what is running right now, and what *was* running and died.
  `run` writes `<worktree>/.orchestra/run.json` (task, pid, run, model, harness, profile, start time) and removes it
  on every exit path; `status` checks the pid, so a killed or crashed run is reported **stale** instead of looking
  alive. `--json` for editor plugins and scripts; `--worktree` to ask about one task.
  The failure this prevents: an orchestrator waiting on a worker that is already gone.
- Offline suite: 93 checks (`tests/status.sh` adds 7: live pid, dead pid, elapsed formatting, the stderr hint, the
  JSON shape, and both empty cases).

## 0.3.0 (2026-11-23)
- **Proofs** ([docs/proofs.md](docs/proofs.md)): `orchestra-worker prove` runs the landing gate
  (`ORCHESTRA_GATE`) and the spec's `proof:` lines in the worktree, without a model, and records one line per check
  bound to a hash of the exact code; a change makes the proof stale. Manual proofs with `--manual`.
- **`orchestra-worker land`**: rebase, squash (claim and wip commits dropped, a written message kept), prove the
  result, push with `Proof:` trailers; refuses on any failing check; retries once if the base moved.
- **`orchestra-worker diff`**: the review diff without generated files (`ORCHESTRA_GENERATED`; still in the stat).
- Offline suite: 86 checks.

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
