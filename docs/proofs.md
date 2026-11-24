# Proofs

A worker's report is a **claim**. A **proof** is evidence orchestra produced itself: it ran a check in the task's
worktree, outside the worker's sandbox and without a model, and recorded the result against a hash of the exact code.

## What a proof is
One line in `<worktree>/.orchestra/proofs.jsonl`:
```json
{"check": "make test", "exit": 0, "secs": 41, "tree": "9f3c…", "at": "2026-11-23T03:40:00Z", "log": "…/proofs/1763869200-1.log"}
```
- `tree` is the git tree hash of everything in the worktree (tracked and untracked, not ignored). Change one byte
  and the proof no longer applies: there is no way to land code other than the code that passed.
- The full output stays in the log file. Only failures are printed, as their last 15 lines.
- A **manual proof** records what a person or the orchestrator checked by hand (`--manual "visual check at 400 px"`),
  for checks a command cannot do. It is listed, not enforced.

## The candidate snapshot
Every successful `prove` (including `prove --manual` and the prove inside `land`) also writes
`<worktree>/.orchestra/candidate.json`: the exact state it passed on.
```json
{"task": "T12", "run": 2, "base": "origin/main", "base_commit": "f072b7f1a2b3…", "tree": "9f3c1a2b4d5e…",
 "spec": "docs/work/tasks/T12-….md", "spec_tree": "…", "at": "2026-11-23T03:40:00Z"}
```
- `run` is the number of run logs in `.orchestra/runs/` (null when there are none). `base` is the `ORCHESTRA_BASE`
  string, and `base_commit` is what it resolved to when the candidate was written (null when it does not resolve).
- `tree` is the proof's tree; `spec` and `spec_tree` record which spec described the task (informational: proofs
  still re-match on the check command string).
- It is written atomically (a temp file beside it, then a rename), and lives under `.orchestra/`, which is excluded
  from the tree hash: recording a candidate never invalidates the proof it records.

`review` shows `candidate: run 2, base origin/main, tree 9f3c1a2b4d5e`. When the worktree has changed since, it adds
`candidate drift: worktree differs from the candidate tree` and the stat of that change, so an orchestrator's own
small fix (or a rebase) is exactly what it sees, not a surprise in the diff. `land` prints
`candidate drift: publishing a tree that differs from the candidate` when the tree it is about to prove differs
from the last candidate; it still re-proves the tree it publishes, and leaves a fresh candidate.

## Which checks run
1. `ORCHESTRA_GATE`: the repository's landing gate, one shell command (`make check`, `scripts/ci.sh`).
2. Every `proof:` line in the task spec, usually in Acceptance:
   ```markdown
   - proof: `go test ./internal/web/ -run Interview`
   ```
Checks run in the worktree with the dev environment from `ORCHESTRA_DEVENV_CMD`, stdin closed.

## Commands
```bash
orchestra-worker diff  T12            # stat of everything, full diff without generated files (ORCHESTRA_GENERATED)
orchestra-worker prove T12            # PASS/FAIL one line per check; already-proven checks are not run again
                                      # (a passing prove writes .orchestra/candidate.json)
orchestra-worker prove T12 --manual "checked the empty state in a browser"
orchestra-worker land  T12            # rebase, squash, prove the result, push with Proof: trailers
```
`land` refuses to push unless every check passes on the code it pushes. It rebases first, so the proof is for the
code that lands, not for an older base. If the push is rejected because the base moved, it rebases, proves and
tries once more. The commit keeps a message written on the branch (claim and wip commits are dropped), else
`<task>: <title>`, and gets one trailer per proof:
```
Proof: pass (41s) tree 9f3c1a2b4d5e: make test
Proof: manual: checked the empty state in a browser
```

## Why this shape
- **Cheap to read**: the orchestrator reads one line per check instead of a worker's narrative and logs.
- **Hard to fake**: the model never writes a proof; orchestra runs the command and hashes the code.
- **Durable**: trailers put the evidence in history, next to the code (`git log --grep '^Proof:'`).
