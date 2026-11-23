# Proposal 0003: scout, review, live progress, and a smaller ops surface

Status: **implemented in 0.5.0** (2026-11-23)

## Evidence
19 worker runs on 17 tasks in one production repository (DeepSeek Flash) cost **$1.25 in total**. Worker tokens are
not where the money or the time goes; the orchestrator's are: writing 500-1100 word specs, then reading reports,
diffs and proofs in four separate calls per run.

13 of 17 runs came back with open questions. The largest group was not a missing decision but **a spec pointing at
the wrong or incomplete code**: a page served by a different file than the one named; a registration pattern that
did not exist; call sites in another package; tests asserting the old behaviour that were not listed (the worker
edited them anyway); an acceptance command that could not run because the code is a separate module; a task whose
allowed paths excluded the files it needed (28 files changed, status partial). `refine` already says "open each
path", but doing it by hand is expensive and still missed these.

About half of the remaining open questions were small calls the worker had already made sensibly (an error-class
name, `$49` against `$49.00`, an aria state). Mixed with blocking questions, they cost review attention they do not
need.

Twice, files were changed outside the task's paths; only a full read of the diff showed it.

Watching was blind: a background run printed nothing until it ended, so the only signs of life were the elapsed
time and the pid.

The eight ops skills were one-line pointers into one guide, and all eight descriptions were loaded into every
session, including application repositories that never do ops work.

## Changes
1. **`scout`**: a read-only worker (checkout and git mounted read-only) checks a draft spec against the code and
   writes `scout.json`: named things and where they really are, files to change (in the spec or not), tests
   affected, patterns to copy, whether commands run, size and split point, undecided calls. A view prints it with
   a block to paste into Touches. This is the delegable half of planning: legwork, no decisions.
2. **`review`**: one screen per finished run. Exit meaning, blocking questions, assumptions, files outside
   Owns/Touches (computed, not claimed), worker checks, proofs for the current tree, ranked diff stat.
3. **`assumptions`** in the report, separate from `open_questions` (now blocking only). Data, privacy, security,
   money, contracts and schema are never assumptions.
4. **Live progress**: one line per tool call during a run, a quiet line after a minute, a finish card; `status`
   shows tool calls, cost so far and the current action; `watch` redraws it. Harness adapters opt in with a
   `<harness>_progress.py` reader.
5. **`clean`**: lists task worktrees with a class (landed, squash-landed, dirty, running, open), removes landed ones
   with `--yes` (never forced, never a branch).
6. **Ops**: eight skills became two (`ops-change`, `ops-incident`); the other playbooks are change types inside the
   one change loop. Installed only with `install.sh --ops`. No rule was dropped (a test greps for each).

## Not done
- A scout cannot run test suites (read-only checkout); it checks that commands exist, not that they pass.
- Progress lines need a harness reader; only pi has one.
