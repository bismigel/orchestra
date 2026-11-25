# Lessons

Spec gaps found in review, one line each: what the spec missed, and the rule that would have caught it.
`orchestra-refine` reads this file.

- 2026-11-25 T2: the spec said to change "the two" README phrases about history; a third occurrence (wrapped over a
  line break) existed, and the worker correctly left it alone. Rule: when a spec changes wording, give the exact
  `grep -n` that finds every occurrence (allowing for line wraps), not a count.
- 2026-11-25 T2: the worktree was made before a related PR merged, so `review` listed that PR's files as "outside
  paths" (the diff against the newer base shows them reversed). Rule: before reading OUTSIDE PATHS, check whether the
  base moved since the worktree was made; if it did, those entries are the base's changes, not the worker's.
