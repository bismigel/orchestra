---
description: Land a reviewed orchestra task the safe way
argument-hint: "<task id> [pr]"
---
Land task $1 with the `orchestra_land` tool (pr=true if "$2" is "pr" or the base branch is protected). It commits,
rebases onto ORCHESTRA_BASE, squashes, proves the exact code with the repository's gate and the spec's `proof:`
lines, and pushes only if every check passes. Never push by hand, never force the base, never `git reset --soft`
from a stale worktree. Before landing, `orchestra_review` must show no unanswered BLOCKING question and no file
outside the task's paths without a reason. Afterwards run `orchestra-worker lessons $1` and append the lines that
would change a future spec to the lessons file. Report the commit (or pull request), the proofs and the cost.
