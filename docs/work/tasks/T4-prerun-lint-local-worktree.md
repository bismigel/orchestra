---
id: T4
title: Pre-run task lint, local worktrees and guide --cat (issue #29, parts 2 and 3)
status: done
depends: none
delegation: worker
---
## Goal
Three small `bin/orchestra-worker` changes from GitHub issue #29, so an orchestrator never has to leave the loop:
`orchestra-worker run` refuses a task spec that fails `orchestra-task lint` before it spends a worker run (scout only
warns), `run --local-worktree` creates a plain local worktree even when `ORCHESTRA_WORKTREE_CMD` would push a claim
branch, and `guide --cat` prints a guide's text so a harness never has to `read` a path outside its workspace.

## Decisions
- **guide**: `cmd_guide` accepts `--cat` as an exact synonym of the existing `--print`. Add one guide name:
  `land` → `$here/skills/claude-code/orchestra-land/SKILL.md` (path is relative to `$here`, not `$here/docs`). Add
  `land` to the "unknown guide" message list. Update the usage comment near the top of the file (line ~32) to
  `orchestra-worker guide [<name>] [--print|--cat]`.
- **Pre-run lint, `run`**: only on a first run with `--spec` (not `--prompt`, not `--feedback`), and only when all of
  these hold: the spec file exists relative to the current directory (`[ -f "$spec" ]`), its first line is exactly
  `---`, its front matter (up to the next `---` line) has an `id:` line, and the spec's real directory equals
  `realpath -m "$repo/$ORCHESTRA_TASKS_DIR"`. Then run, from `$repo`:
  `python3 -I "$here/lib/task_lint.py" "<id>" --tasks-dir "$ORCHESTRA_TASKS_DIR" --base "$ORCHESTRA_BASE" --profile "$ORCHESTRA_PROFILE"`
  (`<id>` is the front-matter id value, trimmed). Exit 0: continue silently. Any non-zero exit: print the lint output
  to stderr and `die` with `task lint failed for <id>: fix the spec, or pass --skip-lint` (exit 2). This runs before
  the worktree is created and also on `--dry-run` (lint is read-only).
- New `run` option `--skip-lint` disables that check. Add it to the run usage string.
- **Pre-run lint, `scout`**: same detection (spec given with `--spec`), same command, but it never fails the scout:
  on a non-zero lint exit print `scout: task lint found problems (the scout runs anyway):` and the lint output to
  stderr, then continue.
- **Local worktree**: new `run` option `--local-worktree`, and a config key `ORCHESTRA_WORKTREE_LOCAL` (default `0`;
  `1` has the same effect as the flag). When set, the worktree is created with the existing default branch
  (`git worktree add -q -b "orchestra/$task" "$wt" "$start_ref"`) and `ORCHESTRA_WORKTREE_CMD` is not run. The
  dry-run message must name the command that would really be used. Declare the key in `load_config` beside
  `ORCHESTRA_WORKTREE_CMD`, and document it in `config/config.example.env` right after `ORCHESTRA_WORKTREE_CMD=`,
  with a one-line comment: remote pushes are deferred to `land`.
- Nothing else in `bin/orchestra-worker` changes behaviour.

## Owns
- bin/orchestra-worker
- config/config.example.env
- tests/prerun.sh (new)

## Touches
- lib/task_lint.py (read only: do not change it)
- tests/run.sh (read it for the fake-harness setup; do not change it)

## Acceptance
New suite `tests/prerun.sh`, modelled on `tests/run.sh` (unset `ORCHESTRA_*`, throwaway `XDG_CONFIG_HOME`, a temp git
repository, the fake harness `tests/fixtures/fake-harness.sh`, `ok`/`bad` counters, exit 1 on any failure). Cases:
1. `guide orchestrator --cat` prints the text of `docs/orchestrator-guide.md` (compare with `cat`), `guide land --cat`
   prints the orchestra-land skill text, `guide land` prints a path ending in `orchestra-land/SKILL.md`.
2. A spec `docs/work/tasks/X1-bad.md` with valid front matter (`id: X1`, title, `status: ready`, `depends: none`,
   `delegation: worker`) but no `## Out of scope` section, committed in the temp repo: `run X1 --spec <it> --dry-run`
   exits 2 and the output contains `L11` and `--skip-lint`.
3. The same with `--skip-lint` exits 0.
4. A spec that passes lint (all sections, an acceptance command in backticks, a `proof:` line, Owns on a new path
   marked `(new)`) runs `--dry-run` with exit 0.
5. A spec outside the tasks dir (e.g. `spec.md` in the repo root, with front matter) is not linted (`--dry-run` exit 0
   even though it lacks Out of scope).
6. `scout X1 --spec <bad spec>` with the scout fixture harness (`tests/fixtures/scout-harness.sh`, see
   `tests/scout.sh` for its setup) still exits 0 and its stderr contains `task lint found problems`.
7. With `ORCHESTRA_WORKTREE_CMD='touch "$PWD/cmd-was-run"; false'`, `run t9 --prompt "x" --local-worktree` creates
   the worktree `<repo>-worktrees/t9` and `cmd-was-run` does not exist; the same with `ORCHESTRA_WORKTREE_LOCAL=1`
   and no flag (task `t10`).

proof: `bash tests/prerun.sh`
proof: `bash tests/all.sh`
proof: `shellcheck -S warning bin/orchestra-worker tests/prerun.sh`

## Out of scope
- `examples/pi/orchestra.ts`, the router, docs and skills (the orchestrator changes those).
- Any change to `lib/task_lint.py` or to how lint itself judges a spec.
- `land`, `prove`, `review` and the push behaviour.
