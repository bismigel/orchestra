---
name: orchestra-refine
description: Make tasks ready for worker agents - run orchestra-task lint, then the judgment half of the definition of ready (decisions written, risky test rows, verified paths, affected tests, current base). Use before launching workers, after decisions change, when a worker reports open questions, or when the user asks to refine stories or tasks.
---

# orchestra-refine

Follow "refine" in `docs/planning-guide.md` in the orchestra repository (from this skill's folder: `../../../docs/planning-guide.md`). For each task (`<id>`, a wave, or all):

1. `orchestra-task lint <ids>`: fix every error it reports.
   Then, for each task beyond a few files, `orchestra-worker scout <id> --spec <task file>`: a read-only worker
   checks the spec against the code (real paths, missed files and tests, broken commands, size). Read its view,
   paste what belongs into Touches, and decide anything it lists as undecided.
2. Judgment checks: user-visible goal; every decision written as a rule (hunt for "should", "maybe", "or",
   "decide"); for `split` tasks, risky test rows written by you, including what must not change; each path opened
   and confirmed to hold what the spec says; tests that assert changed behaviour listed in Touches; visual and live
   checks moved to orchestrator checks; spec matches the current base branch; fits one worker run or gets split.
   The scout does the searching for the paths, tests and size checks; you judge what it found.
3. Apply `docs/work/lessons.md`.
4. Report per task: ready / not ready, what you changed, and the decisions still needed as questions with a
   recommended answer. Only set `status: ready` when it is.
