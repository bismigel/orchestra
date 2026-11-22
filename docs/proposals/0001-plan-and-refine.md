# Proposal 0001: `plan` and `refine`

Status: **proposal** · discuss on the pull request · 2026-11-22

## Why
Worker output is only as good as the spec it gets. In the first production run (one SaaS, six tasks, about $0.50 of
worker time) every problem the orchestrator caught came from the spec, not the model:

| What went wrong | Root cause in the spec | Rule it becomes |
|---|---|---|
| Worker exempted names from redaction | a judgment call left open | **Decisions are written, not implied**; risky rows are given as test cases |
| Worker edited a file it did not own (the landing page) | spec named the page, not the file it lives in | **Every path is verified to exist and to hold what the spec says** |
| Worker edited an existing test | spec didn't foresee a test asserting the old markup | **Touches lists the tests that assert behaviour being changed** |
| Hidden file input gave no feedback | spec optimised a check, not the user's experience | **Each UI task states the user-visible result**, not only the markup |
| Acceptance asked for screenshots | worker has no browser | **Worker acceptance = commands; screenshots are orchestrator checks** |
| Worker read a stale spec | worktree older than the spec rewrite | **Ready means checked against the current base branch** |

So: two orchestrator commands, both ending in artifacts in the repository that workers read.

## `plan`: a planning session for a new project
Run once at the start (and again for a major new phase). Interactive with the human, led by the orchestrator. The
output is a **planning pack** in the repository:

```
docs/plan/brief.md          problem, users, jobs to be done, constraints, non-goals, success measures
docs/plan/scope.md          features (must / should / could / won't), the MVP cut line, release slices
docs/plan/decisions.md      D1…Dn: decided, with the reason and "do not re-litigate without new facts"
docs/plan/architecture.md   stack, data model, integrations, data and security rules (the hard rules)
docs/plan/wireframes/       one HTML page per screen; numbered notes map each element to a story and a rule
docs/work/BOARD.md          waves, dependency graph, ownership map, open decisions
docs/work/tasks/Txx-*.md    every MVP task in the orchestra task format, each passing `refine`
AGENTS.md (or CLAUDE.md)    the rules every agent must follow, generated from decisions and architecture
.orchestra/config.env       dev environment, checks, worktree command
```

### Phases (each ends with a checkpoint the human approves)
1. **Discover.** The orchestrator asks what only the human knows, in rounds of at most four questions, each with a
   recommended default (who uses it, what "done" looks like, budget, hard constraints, data sensitivity). It never
   asks what it can infer from the repository or the conversation.
2. **Decide.** The orchestrator proposes the stack, architecture and data rules as numbered decisions with reasons and
   rejected alternatives. The human approves, edits or rejects each one. Approved decisions are frozen.
3. **Design.** Wireframes for every MVP screen (HTML, one file per screen, design tokens, both themes, phone width),
   each element numbered and tied to a story and to any rule that governs it. For APIs and CLIs: request/response or
   command transcripts instead of screens.
4. **Decompose.** Stories become tasks sized for one worker run, grouped into waves with explicit dependencies and
   disjoint ownership. Each task gets a delegation class (`worker`, `split`, `orchestrator`); `split` tasks name the
   core the orchestrator writes.
5. **Check.** Every task goes through `refine`. The pack is done when the whole first wave is ready.

### What the human sees
A short message per checkpoint ("Here are 9 decisions; 2 need you") and, for wireframes, a link to open them. The
session can stop and resume at any checkpoint: the pack in the repository is the state.

## `refine`: make a task ready (and keep it ready)
`refine <task>|<wave>|all` rewrites tasks until they meet the **definition of ready**, and reports what still needs
the human. Run it before launching workers, after any decision changes, and on a task that came back with open
questions.

### Definition of ready
| # | Check | Mechanical (`orchestra task lint`) or judgment (orchestrator) |
|---|---|---|
| 1 | Front matter complete: id, title, status, depends, delegation | mechanical |
| 2 | Goal states the **user-visible result** in one paragraph | judgment |
| 3 | Every decision the task needs is written in it; none left to the worker | judgment |
| 4 | `split` tasks: required test rows for the risky cases, including negatives (what must not change) | judgment |
| 5 | Owns is disjoint from every other open task (or the tasks are chained) | mechanical |
| 6 | Every path in Owns/Touches exists or is clearly new, and holds what the spec says it does | mechanical + judgment |
| 7 | Touches includes existing tests that assert behaviour this task changes | judgment (grep-assisted) |
| 8 | Worker acceptance is commands and test names only; orchestrator checks are listed separately | mechanical |
| 9 | Size fits one worker run (rule of thumb: ≤ 8 files, ≤ 400 changed lines); otherwise split | estimate |
| 10 | Dependencies are done or explicitly chained; the spec matches the current base branch | mechanical |
| 11 | Out of scope names where the excluded work goes | mechanical |

`refine` output per task: the rewritten spec, a **ready / not ready** verdict, and the decisions it still needs
(asked as questions with recommended answers).

### `orchestra task lint` (new CLI, deterministic)
Checks 1, 5, 6 (existence), 8, 10 and 11 without a model: parses front matter, compares Owns across open tasks,
checks referenced paths against the base branch, flags acceptance lines without a command. Fast enough to run in CI
on every task-file change. The judgment checks stay with the orchestrator.

## Learning loop
After a task lands, the orchestrator adds one line to `docs/work/lessons.md` for each spec gap the review found
(like the table at the top). `refine` reads it, so the checklist grows from real misses instead of guesses.

## What ships
- `skills/claude-code/orchestra-plan/SKILL.md`, `skills/claude-code/orchestra-refine/SKILL.md`
- `docs/planning-guide.md` (the same procedure for any orchestrator)
- `templates/`: brief, scope, decisions, architecture, task, wireframe page (HTML skeleton with tokens and
  numbered notes)
- `bin/orchestra-task` with `lint` (and later `new`, `graph`)
- tests for `lint` against fixture boards

## Open questions
1. Wireframes as HTML (rich, reviewable in a browser) or Markdown/ASCII (diffable, lighter)? Proposal: HTML for
   UI projects, transcripts for APIs and CLIs.
2. Should `plan` also produce a cost estimate per wave (tasks × typical worker cost)?
3. Task file format: keep this repository's front matter, or adopt an existing standard?
