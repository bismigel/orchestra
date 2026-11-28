# Orchestrator guide

Instructions for the orchestrating agent (any agent: Claude Code, Codex, opencode, …). Point your agent at this file
from its instruction file (`AGENTS.md`, `CLAUDE.md`) or install the bundled skill. Read `design.md` once for the why.

## Before delegating a task
1. **Classify it**: `worker`, `split` or `orchestrator` (design.md). If unsure, it is `split`. A multi-file refactor
   in a sensitive area (auth, sessions, headers) is `split`, not `orchestrator`: you settle the invariants and the
   risky test rows, the worker makes the edits across the call sites, generated code and tests.
2. **Write the decisions down.** Every judgment call the task contains becomes a rule in the spec. For `split` tasks,
   write the required test rows (input → exact expected output) for the risky cases yourself, especially the
   negatives: what must *not* change.
3. **Make the acceptance runnable by the worker.** Name test commands and test names. Screenshots and manual steps
   are yours, listed separately as orchestrator checks.
4. **Limit the scope.** Name the paths the worker may change and anything it must not touch.
5. **Scout it** (anything bigger than a few files): `orchestra-worker scout <id> --spec <draft>`. A read-only worker
   (the checkout is mounted read-only) checks the draft against the code: where each named thing really lives, the
   files and tests the spec missed, the pattern to copy, whether the acceptance commands run, and the size. It costs
   cents and ends with an "add to the spec" block you can paste. You still decide what goes in; the scout only
   reports. In the first production pilot most open questions were a spec pointing at the wrong file, which is
   exactly what this catches.

## Launching
```sh
orchestra-worker run <task-id> --spec path/to/spec.md            # first run
orchestra-worker run <task-id> --feedback review.md              # next round, same session
orchestra-worker summary <task-id>                               # status, report and cost so far
orchestra-worker status [--json]                                  # what is running now, and what died silently
```
A first run from a spec in the tasks directory (`ORCHESTRA_TASKS_DIR`, with front matter) runs `orchestra-task lint`
on it before anything is spent, and refuses (exit 2) when lint fails; `--skip-lint` overrides. `scout` only warns.
When `ORCHESTRA_WORKTREE_CMD` pushes a claim branch you may not push yet, `run --local-worktree` (or
`ORCHESTRA_WORKTREE_LOCAL=1`) creates a plain local worktree instead; the push waits for `land`. Never fall back to a
hand-made `git worktree add`: it skips lint and the worker.

Guides load a piece at a time: `orchestra-worker guide --list`, `guide <name> --toc`, `guide <name> --section <n>`,
or `--cat` for the whole text (pi: the `orchestra_guide` tool). They print text, so a harness that guards paths
outside its workspace never has to read the skill's symlink target.

Before a first run, `run` compares the worktree with `ORCHESTRA_BASE`: a worktree with no work yet is rebased onto
it automatically, while one with work is refused (exit 2) when the task's spec changed on the base, so the worker
cannot silently read an old spec. Pass `--allow-stale` to go ahead against the older code instead. `--feedback`
rounds skip the check.
Run it as a background command if your agent supports that, so you are notified when it exits, and keep 2-3 workers
going at most: your review is the bottleneck. Each run is capped by `ORCHESTRA_TIMEOUT`.

A run prints one line per tool call while it works (`T41 03:12 #14 edit internal/web/layout.templ`), a `quiet for`
line when nothing happened for a minute, and a card when it ends: exit meaning, time, cost, blocking questions
first. You do not need to read that output while it runs; the person watching does. When it ends, read only the card
(`sed -n '/^── /,$p' <output>`), or go straight to `review`: the progress lines would cost you tokens for nothing. `ORCHESTRA_PROGRESS=0` turns the
lines off.

Before the run starts, it can refuse (exit 2): **the task is already running** (two runs would share one worktree,
session and report), or **the worktree is stale**: the spec changed on the base since the worktree was made and the
worktree already has work, so the worker would read the old spec. Rebase it, or pass `--allow-stale` when the old
spec is what you want. A worktree with no work yet is simply rebased.

**Budget.** `ORCHESTRA_MAX_COST=0.50` (dollars per run) stops a run whose responses add up to more: exit 5, and the
card says `OVER BUDGET`. It is the guard against a looping worker; the timeout only bounds time. Stopping
`orchestra-worker` itself (Ctrl-C, or your agent stopping the background command) stops the worker too (exit 130).

## Is it still running?
`orchestra-worker status` answers that, and nothing else should be used to guess: it reads a per-run state file and
checks the pid, so a worker that was killed, OOM-ed or timeout-ed shows as **stale** rather than as a run that is
quietly still going. For a live run it also shows tool calls, cost so far and what the worker is doing now (`quiet
5m` when no event arrived for a while: a long command, or stuck). `orchestra-worker watch` is the same view, redrawn
every two seconds with each worker's last actions, for a person to keep open in a terminal. `--json` feeds editor
widgets ([examples/pi/workers.ts](../examples/pi/workers.ts)).

## Reviewing a finished run
Exit codes: `0` ran and reported · `3` a disallowed model answered: discard the run · `4` no valid report ·
`124` timed out · other: the harness failed (read `.orchestra/runs/run-N.err`).

Then, in this order:
1. `orchestra-worker review <task>`: one screen with how the run ended, **blocking** questions (decide each one),
   **assumed** calls (skim: small choices the worker made where the spec was silent), files changed **outside** the
   spec's Owns/Touches, the worker's claimed checks, which proofs hold for this exact code, and a ranked diff stat.
   Start here instead of reading the report, the diff and the proofs separately. When a prove passed, it also shows
   a `candidate:` line (the run, base and tree the proofs bound to). If you changed the worktree yourself, or
   rebased it, it adds `candidate drift:` with the stat of the difference, so you see exactly what moved since the
   proof ([docs/proofs.md](proofs.md)).
2. Read the whole diff: `orchestra-worker diff <task>` (generated files appear only in the stat). Every file the
   review listed as outside the paths needs a reason.
3. Run the checks yourself: `orchestra-worker prove <task>`. Do not reuse the worker's results: its report is a
   claim, a proof is evidence ([docs/proofs.md](proofs.md)).
4. **Probe.** For anything touching data, privacy, security or money, write a throwaway test with your own inputs,
   especially ones the worker's tests don't cover, and look at the actual outputs. This is where bugs are found.
5. Decide: land it, fix a small decided issue yourself, or send feedback.

## Writing feedback
Concrete beats general. Give a table of failing cases (input, the worker's output, the required output), the rule
that makes them fail, and the test rows to add. Keep the rules you set non-negotiable ("always", "never") where they
protect data. After about three rounds, take the task over.

## Landing
Workers cannot commit. `orchestra-worker land <task>` does it for you: it commits what is left, rebases onto
`ORCHESTRA_BASE`, squashes (claim and wip commits are dropped; a message written on the branch is kept), proves the
result, and pushes with `ORCHESTRA_PUSH_CMD` only if every check passes, adding `Proof:` trailers. If the worktree
changed since the last proof, it prints `candidate drift:` with the stat before it re-proves, and the fresh proof is
what counts. Record the task's cost from `orchestra-worker summary` if you track it.

**Protected base branch** (pull requests required): `orchestra-worker land <task> --pr`, or `ORCHESTRA_LAND=pr`.
Everything up to the proven, squashed commit is the same; then it pushes that commit to `orchestra/<task>`
(`ORCHESTRA_PR_BRANCH`) and opens a pull request with `ORCHESTRA_PR_CMD` (default: `gh pr create` when `gh` is
installed; `none` to only push). Placeholders `{branch}`, `{base}`, `{title}`, `{body}` expand as variables, so put
them in double quotes; a title is data, never code.

**Local base** (an integration branch, or a forge you cannot reach yet): set `ORCHESTRA_BASE` to the local branch
name (`plan/x` counts as local when `plan` is not a configured remote). `land` then skips the fetch, rebases, squashes
and proves as usual, and moves the branch with a compare-and-swap: if the branch moved while proving, it rebases and
proves again. When the branch is checked out somewhere, that checkout is fast-forwarded, and only if it has no
uncommitted changes to tracked files; otherwise land refuses and nothing moves. `--pr` is refused (there is no
remote). `doctor` says which kind of base you have. Publish the integration branch itself later, normally.

**Record what the spec missed.** `orchestra-worker lessons <task>` turns the run's blocking questions, files outside
the paths and assumptions into dated draft lines for the lessons file. Keep the ones that would change a future spec,
write the rule each one needs, and append them: `refine` applies that file to every later task. A lessons file that
stays empty means every spec gap gets rediscovered by a worker, at review time.

Worktrees of landed tasks are clutter. `orchestra-worker clean` lists them with the reason (landed, squash-landed,
dirty, running, open); `--yes` removes the landed ones with `git worktree remove` (never forced, never a branch).
Squash-merged tasks (landed through a pull request) need `--include-squashed`; a worktree with uncommitted work or a
live run is never removed. Before removing anything, `clean --yes` archives each task (runs, exit codes, cost,
questions, denied egress) to a ledger in the git directory; `orchestra-worker history` shows live and archived tasks
with their runs, tokens and cost, and the project's total spend.

## Setup check
`orchestra-worker doctor` before the first run in a repository, and whenever runs fail in odd ways: config files,
model and allowlist, harness, sandbox (and whether private network namespaces work, for `ORCHESTRA_EGRESS_ALLOW`),
the key (length and fingerprint only, never the value), base, gate, dev environment, bind mounts, budget and stale
run state. It exits 1 on anything that would break a run.

**Squash by rebasing, never by resetting a stale worktree.** A worktree is a snapshot of when the task started; a
`git reset --soft origin/main` from it silently reverts every file that changed on `main` since. `land` rebases
first, then squashes onto the base it just rebased on, which is safe. (This happened in the first production pilot
before `land` existed: a squash reverted unrelated docs.)

## When orchestra itself is wrong
A bug in `orchestra-worker`, `orchestra-task`, a prompt, a skill or the pi extension (a crash, a wrong exit code, a
misleading message, a guard that let something through, a test that flakes) is reported where it can be fixed: an
issue on `bismigel/orchestra`. A spec gap is not an orchestra bug; it goes to the lessons file. Open the issue as
soon as you have the evidence, without asking first, then carry on with the task (work around it if you can, and say
so in the issue).

1. **Check for a duplicate**: `gh issue list --repo bismigel/orchestra --state all --search "<words>"`. If one exists,
   add your replication as a comment (`gh issue comment <n>`) instead of opening a new issue.
2. **Replicate it in a throwaway repository**, not in the user's: `git init` a temp dir, the smallest spec or command
   that shows the problem, and the fake harness (`ORCHESTRA_HARNESS=<orchestra>/tests/fixtures/fake-harness.sh`) when
   no model is needed. If it only shows in a real run, quote the commands and the relevant output lines instead.
3. **Find a possible fix**: the file and line, why it happens, and a short diff or a description of the change, with
   the test that would catch it (`tests/<suite>.sh`).
4. **Redact**: the repository is public. No secrets or tokens, no private hostnames, IPs, repository or customer
   names, personal data or file contents from the user's project. Use placeholders (`<repo>`, `example.com`).
5. **Open it**: `gh issue create --repo bismigel/orchestra --label bug --title "<what is wrong, in one line>"
   --body-file <file>`, with these parts:

~~~markdown
**What happened**
One paragraph: what you ran, what you expected, what you got.

**Replication**
orchestra <git -C <orchestra> rev-parse --short HEAD>, harness <pi version>, OS
```sh
<commands from an empty temp dir to the failure>
```
Output (trimmed): ...

**Possible fix**
`<file>:<line>`: why it happens, and the change (a short diff). Test: `tests/<suite>.sh` case "<name>".

**Workaround**
What you did meanwhile, if anything.
~~~

Tell the user the issue URL in your next message. Fixing it is a separate task (a pull request), not part of filing.

