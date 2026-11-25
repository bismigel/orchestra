---
name: orchestra-land
description: Land a reviewed orchestra task the safe way - check the review is clean, land with proofs (or a pull request on a protected base), then record the lessons. Use when the user says "land T12", "ship this task", "merge the worker's run", or after a worker run you reviewed is ready.
---

# orchestra-land: `<task id> [pr]`

Land a task only after you reviewed it (the `orchestra` skill, step 4).

1. **Gate.** `orchestra-worker review <id>` must show no unanswered BLOCKING question, a reason for every file outside
   the task's paths, and a `candidate:` line from a passing prove. On `candidate drift:` (the worktree changed since
   that proof), run `orchestra-worker prove <id>` again first.
2. **Land.** `orchestra-worker land <id>`: it commits, rebases onto `ORCHESTRA_BASE`, squashes, proves the exact code
   with the repository's gate and the spec's `proof:` lines, and pushes only if every check passes. Add `--pr` when
   the user says "pr" or the base branch is protected: it pushes `orchestra/<id>` and opens a pull request instead.
   Never push by hand, never force the base, never `git reset --soft` from a stale worktree.
3. **Local base** (an integration branch, or the forge is unreachable): set `ORCHESTRA_BASE` to the local branch and
   land as usual. `land` moves that branch in place (compare-and-swap, fast-forwarding a clean checkout of it) instead
   of pushing; `--pr` is refused. A checkout of the base with uncommitted changes makes it refuse: commit or stash
   first. Publish the integration branch itself later, through the normal path.
4. **Record.** `orchestra-worker lessons <id>`; append the lines that would change a future spec, with the rule, to
   the repository's lessons file. Then set the task's `status: done` and its board row.
5. **Report** the commit (or pull request), the proofs, the rounds and the cost (`orchestra-worker summary <id>`).
