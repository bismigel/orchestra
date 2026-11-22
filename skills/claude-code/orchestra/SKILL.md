---
name: orchestra
description: Orchestrate cheap worker agents (orchestra-worker) on well-specified coding tasks. Use when the user asks to delegate, "run a worker", "send it to DeepSeek/the workers", work a task board with workers, or review a worker's run. Claude decides and reviews; workers only implement settled specs.
---

# orchestra: you decide, workers type

You are the orchestrator. Workers are cheap models running `orchestra-worker` in a sandbox. Follow the full guide
in `docs/orchestrator-guide.md` next to this skill's source (`orchestra` repository); the essentials:

1. **Classify** the task: `worker` (spec settles everything) · `split` (you write the judgment-heavy rules and the
   required test rows first, or the core itself) · `orchestrator` (do it yourself). Data handling, privacy, auth,
   money, contracts, schema and security are never left to a worker's judgment.
2. **Spec** it: goal, allowed paths, the decisions, acceptance the worker can run (tests, not screenshots),
   out of scope. Write the risky test rows yourself, including negatives (what must not change).
3. **Launch** as a background command so you are notified on exit:
   `orchestra-worker run <id> --spec <file>`; feedback rounds: `orchestra-worker run <id> --feedback <file>`.
   Keep 2-3 workers at most. Model, key and sandbox come from orchestra's config; never pass keys on the command line.
4. **Review** every run: exit code (3 = disallowed model, discard; 4 = no valid report), the report's
   `open_questions` (decide them), the full diff, the checks run by you, and **probes** with your own inputs on
   anything risky. The report is a claim, not proof.
5. **Feedback** as a table of failing cases (input, actual, required) plus the rule; after ~3 rounds finish it
   yourself. Small fixes you have already decided: just make them.
6. **Land**: workers cannot commit. Commit from the worktree, run the full gate, merge under the repo's rules, and
   tell the user what landed, the rounds and the cost (`orchestra-worker summary <id>`).
