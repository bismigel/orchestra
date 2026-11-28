---
name: orchestra
description: Orchestrate cheap worker agents (orchestra-worker) on well-specified coding tasks. Use when the user asks to delegate, "run a worker", "send it to DeepSeek/the workers", work a task board with workers, or review a worker's run. Claude decides and reviews; workers only implement settled specs.
---

# orchestra: you decide, workers type

You are the orchestrator. Workers are cheap models running `orchestra-worker` in a sandbox; they implement settled
specs and never commit. This page is the loop. Details load on demand, one section at a time:
`orchestra-worker guide --list`, then `guide <name> --toc` and `guide <name> --section <n>` (in pi: the
`orchestra_guide` tool). Never `read` a guide by path outside the workspace. New repository or anything odd:
`orchestra-worker doctor` first.

1. **Classify**: `worker` (the spec settles everything) · `split` (you write the judgment-heavy rules and the risky
   test rows, or the core; the worker does the rest) · `orchestrator` (do it yourself). If unsure: `split`. Data,
   privacy, auth, money, contracts, schema and security are never left to a worker's judgment, but a multi-file
   refactor in such an area is still `split`. Several native edits in a row on source files means you skipped the
   spec.
2. **Spec**: goal, Owns/Touches paths, decisions, acceptance the worker can run with `proof:` lines, out of scope.
   Write the risky test rows yourself, negatives included. Beyond a few files, scout the draft first:
   `orchestra-worker scout <id> --spec <draft>` (read-only, cents). Then `orchestra-task lint <id> --strict`.
3. **Launch** in the background: `orchestra-worker run <id> --spec <file>` (later rounds: `--feedback <file>`). At
   most 2-3 workers. Model, key and sandbox come from config: never put a key on the command line. Read only the
   end card (`sed -n '/^── /,$p' <log>`). Exit 2 = refused (lint failed, already running, or a stale spec:
   `--allow-stale` if intended); exit 5 = over `ORCHESTRA_MAX_COST`, find out why first.
   If the worktree command would push a branch you may not push yet: `run --local-worktree`.
   `orchestra-worker status` shows what is running.
4. **Review** every run: `orchestra-worker review <id>` (decide each **blocking** question, skim **assumed** calls,
   check files outside the paths), then `orchestra-worker diff <id>`, `orchestra-worker prove <id>` (a report is a
   claim, a proof is evidence) and your own probes on anything risky. → `guide orchestrator --section review`
5. **Feedback** as a table of failing cases (input, actual, required) plus the rule; after ~3 rounds finish it
   yourself. → `guide orchestrator --section feedback`
6. **Land** a reviewed task: `orchestra-worker land <id>` (`--pr` on a protected base). Tell the user
   what landed, the rounds and the cost (`orchestra-worker summary <id>`), then append the spec gaps from
   `orchestra-worker lessons <id>` to the lessons file. → `guide orchestrator --section landing`

**When orchestra itself is wrong** (a bug, a misleading message, a missing guard in `orchestra-worker`, a skill or the
pi extension; not a spec gap, which goes to lessons): open an issue on `bismigel/orchestra` right away, without
asking, with a replication and a possible fix. → `orchestra-worker guide orchestrator --section "orchestra itself"`

On demand, not by default: `orchestra-worker guide jev` (the `decide` second opinion), `guide ops`
(infrastructure), `guide planning` (plan and refine a board).
