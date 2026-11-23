# Changelog

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
