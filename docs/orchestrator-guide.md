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
```
Run it as a background command if your agent supports that, so you are notified when it exits, and keep 2-3 workers
going at most: your review is the bottleneck. Each run is capped by `ORCHESTRA_TIMEOUT`.

## Reviewing a finished run
Exit codes: `0` ran and reported · `3` a disallowed model answered: discard the run · `4` no valid report ·
`124` timed out · other: the harness failed (read `.orchestra/runs/run-N.err`).

Then, in this order:
1. Read `.orchestra/report.json`, especially `open_questions` and `out_of_scope_needed`: decide each open question.
2. Read the whole diff (`git -C <worktree> diff`). Check it stays inside the task's paths.
3. Run the checks yourself. Do not reuse the worker's results.
4. **Probe.** For anything touching data, privacy, security or money, write a throwaway test with your own inputs,
   especially ones the worker's tests don't cover, and look at the actual outputs. This is where bugs are found.
5. Decide: land it, fix a small decided issue yourself, or send feedback.

## Writing feedback
Concrete beats general. Give a table of failing cases (input, the worker's output, the required output), the rule
that makes them fail, and the test rows to add. Keep the rules you set non-negotiable ("always", "never") where they
protect data. After about three rounds, take the task over.

## Landing
Workers cannot commit. Commit from the worktree yourself, run the full gate, and merge under your repository's rules.
Record the task's cost from `orchestra-worker summary` if you track it.

**Squash by rebasing, never by resetting.** A worktree is a snapshot of when the task started. If you squash with
`git reset --soft origin/main` from it, every file that changed on `main` since then is silently reverted in your
commit. Instead: commit in the worktree, `git rebase origin/main`, then squash (`git rebase -i` or
`git merge --squash` onto a fresh branch from `origin/main`), and check `git diff --stat origin/main` lists only the
task's paths before pushing. (This happened in the first production pilot: a squash reverted unrelated docs.)
