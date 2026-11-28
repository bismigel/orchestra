# Lessons

Spec gaps found in review, one line each: what the spec missed, and the rule that would have caught it.
Refining a task (`guide planning --section refine`) applies this file.

- 2026-11-25 T2: the spec said to change "the two" README phrases about history; a third occurrence (wrapped over a
  line break) existed, and the worker correctly left it alone. Rule: when a spec changes wording, give the exact
  `grep -n` that finds every occurrence (allowing for line wraps), not a count.
- 2026-11-25 T2: the worktree was made before a related PR merged, so `review` listed that PR's files as "outside
  paths" (the diff against the newer base shows them reversed). Rule: before reading OUTSIDE PATHS, check whether the
  base moved since the worktree was made; if it did, those entries are the base's changes, not the worker's.
- 2026-11-28 T4: Owns/Touches entries without backticks are not parsed as paths, so review flagged every owned file as
  outside the paths. Rule: write each Owns/Touches entry as a backticked path (`bin/orchestra-worker`).
- 2026-11-28 T4: a new check in front of `run` (pre-run lint) broke another suite whose fixture specs are minimal on
  purpose (tests/freshness.sh). Rule: a task that adds a gate to a command lists in Touches every suite that calls that
  command with a fixture spec (`grep -l 'run .*--spec' tests/*.sh`), and says how each should pass.
- 2026-11-28 T5: the spec said herdr output must never reach orchestra-worker's output, but no acceptance case
  checked it, and the worker silenced only stderr. Rule: every "never" or "must not" in Decisions gets its own
  acceptance case that would fail if it broke (here: a fake that prints a marker, and an assert the marker is absent).
