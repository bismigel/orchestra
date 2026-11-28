# Design

## The idea in one paragraph
A strong model (the **orchestrator**) is good at judgment and expensive. A cheap, fast model (the **worker**) is good
at typing and costs cents per task. orchestra splits software work along that line: the orchestrator decides (design,
rules, edge cases, the tests that pin them) and reviews; workers implement the settled remainder in a sandbox and
report back. The orchestrator verifies every claim before anything is merged. Nothing a worker does reaches a shared
branch without that review.

## Roles
| | Orchestrator | Worker |
|---|---|---|
| Who | a strong model in an interactive agent (Claude Code, Codex, opencode, …) or you | a cheap model in a headless harness (pi today), one per task |
| Does | classify tasks, write specs and decisions, launch workers, review diffs, run checks, give feedback, merge | read the spec, implement, run checks, write a report |
| Never | delegate a judgment call | decide an unsettled question, weaken a protection, push or merge |
| Sees | everything you allow it to | its worktree, read-only system dirs, a scratch home; no secrets |

## Delegation classes
Classify every task before delegating it:
- **worker**: the spec settles every decision (UI, CSS, wiring, fixtures, tests written from a given table, docs).
  Delegate all of it.
- **split**: the task has a judgment-heavy core (data handling, privacy, auth, money, contracts, schema, security,
  concurrency). The orchestrator writes the decisions as non-negotiable rules plus required test rows (or writes the
  core itself); the worker does the mechanical rest.
- **orchestrator**: judgment end to end (architecture, pricing, incident fixes, anything you would not let a junior
  merge unreviewed). Not delegated.

A sensitive area does not make a task `orchestrator`. A refactor that touches auth, sessions or headers across many
files is `split`: the orchestrator diagnoses, writes the invariants as a state table with the risky test rows (or
writes a minimal core itself), lints and scouts the spec, and delegates the multi-file edits, call sites, generated
code and test iteration. `orchestrator` is for work whose judgment is in every line, not for mechanical edits that
happen to sit inside a sensitive module. If you find yourself making the fourth native edit in a row, stop and write
the spec.

A worker that meets an undecided judgment call stops and lists it under `open_questions`. That is a success, not a
failure: it means the spec missed something and the orchestrator should decide it.

## The loop
1. **Spec.** A task file with: goal, the paths it may change, decisions already made, acceptance checks the worker
   can run itself (tests, not screenshots), and what is out of scope.
2. **Launch.** `orchestra-worker run <id> --spec <file>`: creates or reuses the task's worktree, runs the worker in
   the sandbox with the fixed model, and writes events, usage and `.orchestra/report.json`.
3. **Verify.** The run already failed if a disallowed model answered (exit 3) or the report is missing or invalid
   (exit 4). Then the orchestrator reads the diff, runs the checks itself, and **probes** risky paths with its own
   inputs. The report is a claim, not proof.
4. **Feedback or finish.** Problems go back to the same worker session as concrete failing cases (input, actual
   output, required output) plus rules: `orchestra-worker run <id> --feedback review.md`. After about three rounds
   the orchestrator finishes the task itself. Small fixes the orchestrator has already decided are faster done
   directly than re-delegated.
5. **Land.** The orchestrator commits (workers cannot), runs the full gate, and merges under the repository's rules.

## Why these choices
- **One model per run, enforced.** Cost and behaviour stay predictable; a harness silently falling back to another
  model fails the run instead of surprising you on the bill.
- **Sessions resume.** Feedback continues the worker's conversation (its context is cheap to keep: providers cache
  it), so round two costs a fraction of round one.
- **Worktrees per task.** Parallel workers never touch each other's files, and a bad run is one `git worktree
  remove` away from gone.
- **Workers cannot commit or push.** The only path to a shared branch goes through review.
- **Plain files, no service.** Everything is a script, a prompt and JSON. Durable or remote execution can come later
  behind the same interface (`run`, `summary`, the report schema) without changing how orchestrators use it.

## What it costs (first real task)
A privacy-sensitive redaction task (regex plus NER rules, 40 table-driven test cases, fixtures): two worker rounds,
99 model responses on DeepSeek Flash, **$0.15** in total. The orchestrator's review found two privacy bugs in round
one, which became required test rows; round two fixed them; one last title-word fix was done by the orchestrator.

## Lessons baked in
- Workers make judgment calls unless told not to, and the first ones they make are where the bugs are.
- A report saying "all checks pass" is usually true for the checks the worker chose; probe the inputs it didn't.
- Bash reads scripts lazily: a launcher edited mid-run corrupts the run. `orchestra-worker` runs from one function.
- Secrets on command lines are visible in the process list; keys travel on a file descriptor.
- A test that skips because a dependency is missing has not passed. Say so in the worker prompt.
