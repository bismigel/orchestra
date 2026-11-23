# Orchestrator guide

Instructions for the orchestrating agent (any agent: Claude Code, Codex, opencode, …). Point your agent at this file
from its instruction file (`AGENTS.md`, `CLAUDE.md`) or install the bundled skill. Read `design.md` once for the why.

## Before delegating a task
1. **Classify it**: `worker`, `split` or `orchestrator` (design.md). If unsure, it is `split`.
2. **Write the decisions down.** Every judgment call the task contains becomes a rule in the spec. For `split` tasks,
   write the required test rows (input → exact expected output) for the risky cases yourself, especially the
   negatives: what must *not* change.
3. **Make the acceptance runnable by the worker.** Name test commands and test names. Screenshots and manual steps
   are yours, listed separately as orchestrator checks.
4. **Limit the scope.** Name the paths the worker may change and anything it must not touch.

## Launching
```sh
orchestra-worker run <task-id> --spec path/to/spec.md            # first run
orchestra-worker run <task-id> --feedback review.md              # next round, same session
orchestra-worker summary <task-id>                               # status, report and cost so far
orchestra-worker status [--json]                                  # what is running now, and what died silently
```
Run it as a background command if your agent supports that, so you are notified when it exits, and keep 2-3 workers
going at most: your review is the bottleneck. Each run is capped by `ORCHESTRA_TIMEOUT`.

## Is it still running?
`orchestra-worker status` answers that, and nothing else should be used to guess: it reads a per-run state file and
checks the pid, so a worker that was killed, OOM-ed or timeout-ed shows as **stale** rather than as a run that is
quietly still going. A stale row names the file to delete and the task to re-run. `--json` exists for a UI: an
editor can poll it and show the count and elapsed time while you do something else.

## Reviewing a finished run
Exit codes: `0` ran and reported · `3` a disallowed model answered: discard the run · `4` no valid report ·
`124` timed out · other: the harness failed (read `.orchestra/runs/run-N.err`).

Then, in this order:
1. Read `.orchestra/report.json`, especially `open_questions` and `out_of_scope_needed`: decide each open question.
2. Read the whole diff: `orchestra-worker diff <task>` (generated files appear only in the stat). Check it stays
   inside the task's paths.
3. Run the checks yourself: `orchestra-worker prove <task>`. Do not reuse the worker's results: its report is a
   claim, a proof is evidence ([docs/proofs.md](proofs.md)).
4. **Probe.** For anything touching data, privacy, security or money, write a throwaway test with your own inputs,
   especially ones the worker's tests don't cover, and look at the actual outputs. This is where bugs are found.
5. Decide: land it, fix a small decided issue yourself, or send feedback.

## Writing feedback
Concrete beats general. Give a table of failing cases (input, the worker's output, the required output), the rule
that makes them fail, and the test rows to add. Keep the rules you set non-negotiable ("always", "never") where they
protect data. After about three rounds, take the task over.

## Landing
Workers cannot commit. `orchestra-worker land <task>` does it for you: it commits what is left, rebases onto
`ORCHESTRA_BASE`, squashes (claim and wip commits are dropped; a message written on the branch is kept), proves the
result, and pushes with `ORCHESTRA_PUSH_CMD` only if every check passes, adding `Proof:` trailers. Record the task's
cost from `orchestra-worker summary` if you track it.

**Squash by rebasing, never by resetting a stale worktree.** A worktree is a snapshot of when the task started; a
`git reset --soft origin/main` from it silently reverts every file that changed on `main` since. `land` rebases
first, then squashes onto the base it just rebased on, which is safe. (This happened in the first production pilot
before `land` existed: a squash reverted unrelated docs.)
