---
name: orchestra
description: Orchestrate cheap worker agents (orchestra-worker) on well-specified coding tasks. Use when the user asks to delegate, "run a worker", "send it to DeepSeek/the workers", work a task board with workers, or review a worker's run. Claude decides and reviews; workers only implement settled specs.
---

# orchestra: you decide, workers type

**New repository, or anything odd?** Run `orchestra-worker doctor` first: it checks sandbox, harness, key (never
printed), model, base, gate and dev environment, and says what to fix.

You are the orchestrator. Workers are cheap models running `orchestra-worker` in a sandbox. Follow the full guide
printed by `orchestra-worker guide orchestrator`; the essentials:

1. **Classify** the task: `worker` (spec settles everything) · `split` (you write the judgment-heavy rules and the
   required test rows first, or the core itself) · `orchestrator` (do it yourself). Data handling, privacy, auth,
   money, contracts, schema and security are never left to a worker's judgment.
2. **Spec** it: goal, allowed paths, the decisions, acceptance the worker can run (tests, not screenshots),
   out of scope. Write the risky test rows yourself, including negatives (what must not change). For anything
   beyond a few files, **scout the draft first**: `orchestra-worker scout <id> --spec <draft>` (read-only worker,
   cents) reports real paths, missed files and tests, broken commands and size, with a block to paste into
   Touches. Delegating that legwork is cheaper than verifying paths yourself.
3. **Launch** as a background command so you are notified on exit:
   `orchestra-worker run <id> --spec <file>`; feedback rounds: `orchestra-worker run <id> --feedback <file>`.
   Keep 2-3 workers at most. Model, key and sandbox come from orchestra's config; never pass keys on the command line.
   Exit 2 before a run means it refused: the task is already running, or its spec changed on the base since the
   worktree was made (rebase it, or `--allow-stale` if the old spec is intended). Exit 5 means it passed
   `ORCHESTRA_MAX_COST`: read why before running it again.
   The run's output has one progress line per tool call, for the user. When it ends, read only the card:
   `sed -n '/^── /,$p' <output file>` (or go straight to `review`), not the whole log.
4. **Review** every run, starting with `orchestra-worker review <id>`: exit meaning, **blocking** questions (decide
   them), **assumed** calls (skim), files outside the spec's paths, claimed checks, proofs for the exact code, diff
   stat. Then the full diff (`orchestra-worker diff <id>`), your own run of the checks (`orchestra-worker prove <id>`;
   a report is a claim, a proof is evidence), and **probes** with your own inputs on anything risky.
   After a passing prove, `review` shows a `candidate:` line (the run, base and tree the proofs bound to). If you
   edit or rebase the worktree afterwards it shows `candidate drift:` with the stat: prove again before you land.
   While runs are going, `orchestra-worker status` shows each one's current action; point the user at
   `orchestra-worker watch` if they want a live view.
5. **Feedback** as a table of failing cases (input, actual, required) plus the rule; after ~3 rounds finish it
   yourself. Small fixes you have already decided: just make them.
6. **Land** with the `orchestra-land` skill, or directly: `orchestra-worker land <id>` (rebase, squash, prove the
   exact code, push with `Proof:` trailers; it refuses on any failing check, and reports `candidate drift:` if the
   worktree moved since the last proof). A local-branch `ORCHESTRA_BASE` is moved in place instead of pushed. Protected base branch: `orchestra-worker land <id> --pr` pushes a branch and opens
   a pull request instead. Tell the user what landed, the rounds and the cost (`orchestra-worker summary <id>`).
   Then **record what the spec missed**: `orchestra-worker lessons <id>` drafts lines from the run's blocking
   questions, outside-path files and assumptions; keep the ones that would change a future spec, write the rule,
   append them to the lessons file (refine reads it). `review` shows `lessons N spec gap(s)` when there are any.
   Afterwards `orchestra-worker clean` lists worktrees that can go (`--yes` archives each to the ledger, then
   removes it); `orchestra-worker history` shows every task's runs and cost, cleaned-up ones included.
