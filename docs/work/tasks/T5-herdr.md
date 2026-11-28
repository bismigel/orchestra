---
id: T5
title: Optional herdr support - a live watch pane and a notification per worker run
status: done
depends: none
delegation: worker
---
## Goal
When the orchestrator runs inside a herdr pane (https://herdr.dev, `HERDR_ENV=1`), `orchestra-worker run` and
`orchestra-worker scout` show the run in herdr without being asked: a small sibling pane with
`orchestra-worker watch <task>` that closes itself when the run ends, and a herdr notification with the exit when it
finishes. Outside herdr, or with herdr missing, nothing changes. herdr is never required and a herdr failure never
changes an exit code or an output line other than the ones below.

## Decisions
- New config key `ORCHESTRA_HERDR`, declared in `load_config` (default `auto`). Values: `auto` (pane and
  notification), `notify` (notification only), `off` (nothing). Any other value: `die "ORCHESTRA_HERDR must be auto,
  notify or off (got '<value>')"` (exit 2), checked in `load_config` next to the `ORCHESTRA_JEV` check.
- `herdr_on`: true only when `ORCHESTRA_HERDR` is not `off`, `HERDR_ENV` is exactly `1`, and `command -v herdr`
  succeeds. Every herdr call below is made only when `herdr_on` is true, runs as
  `timeout 5 herdr ... 2>/dev/null`, and its failure is ignored (`|| true`); nothing it prints reaches stdout or
  stderr of orchestra-worker except as stated.
- `herdr_watch_pane <here> <repo> <task>` (only when `ORCHESTRA_HERDR=auto`): run
  `herdr pane split --current --direction down --ratio 0.3 --cwd "<repo>" --no-focus`, read the new pane id from its
  JSON stdout at `.result.pane.pane_id` (parse with `python3 -I -c`; no id, or invalid JSON: return quietly), then
  `herdr pane run <id> "<here>/bin/orchestra-worker watch <task>; exit"` with `<here>/bin/orchestra-worker` and
  `<task>` shell-quoted with `printf %q`. `watch` already returns when no worker runs, so `; exit` closes the pane.
  Called in the run path right after `write_run_state` (so `run.json` exists when `watch` starts) and in `cmd_scout`
  right after its `write_run_state`.
- `herdr_notify_end <task> <rc> <kind>`: when `herdr_on` (both `auto` and `notify`), run
  `herdr notification show "orchestra <kind> <task>: exit <rc>" --body "next: orchestra-worker review <task>" --sound <s>`
  where `<kind>` is `run` or `scout`, the body for a scout is `next: read the scout view`, and `<s>` is `done` when
  `rc` is 0, else `request`. Called once per run after `print_summary` (run) and once per scout just before each of
  its `return` statements after `launch_worker` (including the error returns 3, 4, 5) and at its normal end.
- `doctor` gains one line after the worktrees line: `herdr_on` true: `info  herdr: in a herdr pane (ORCHESTRA_HERDR=<value>)`;
  `HERDR_ENV=1` but no `herdr` binary: `warn  herdr: HERDR_ENV=1 but herdr is not on PATH` (counts as a warning);
  otherwise `info  herdr: not in a herdr pane (optional)`. With `ORCHESTRA_HERDR=off`: `info  herdr: off`.
- `--dry-run` makes no herdr call.
- Document the key in `config/config.example.env` (a short commented block, after `ORCHESTRA_WORKTREE_LOCAL`),
  and add the comment line `#   watch pane and notification when run inside herdr (ORCHESTRA_HERDR)` nowhere else.

## Owns
- `bin/orchestra-worker`
- `config/config.example.env`
- `tests/herdr.sh` (new)

## Touches
- `tests/run.sh` (read for the fake-harness setup; do not change)
- `tests/scout.sh` (read for the scout fixture setup; do not change)
- `tests/doctor.sh` (must keep passing; do not change)

## Acceptance
New suite `tests/herdr.sh`, modelled on `tests/run.sh` (unset every `ORCHESTRA_*` and `HERDR_*` variable first,
throwaway `XDG_CONFIG_HOME`, temp git repo, fake harness, `ok`/`bad`, exit 1 on any failure). A fake `herdr` script
in a temp dir on `PATH` appends `$*` as one line to `$HERDR_LOG`; for `pane split` it prints
`{"result":{"pane":{"pane_id":"w1:p9"}}}`; when `FAKE_HERDR_FAIL=1` it exits 1 printing garbage. Cases:
1. `HERDR_ENV=1`, default config: `run T1 --prompt x` exits 0; the log has a `pane split --current --direction down`
   line with `--no-focus`, a `pane run w1:p9` line containing `watch T1; exit`, and one `notification show` line
   containing `orchestra run T1: exit 0` and `--sound done`.
2. No `HERDR_ENV`: same run, exit 0, the log is empty (or missing).
3. `HERDR_ENV=1 ORCHESTRA_HERDR=off`: exit 0, log empty.
4. `HERDR_ENV=1 ORCHESTRA_HERDR=notify`: exit 0, log has a `notification show` line and no `pane` line.
5. `HERDR_ENV=1 FAKE_HERDR_FAIL=1`: exit 0 and the end card (`── T5 · run 1 exit 0`) is still printed.
6. A run that ends non-zero (the fake harness writing no report, see `tests/run.sh` for how it exits 4): the
   notification line has `exit 4` and `--sound request`.
7. `ORCHESTRA_HERDR=bogus`: `run ... --dry-run` exits 2 with `ORCHESTRA_HERDR must be auto, notify or off`.
8. `--dry-run` with `HERDR_ENV=1`: log empty.
9. `scout S1 --spec spec.md` with `HERDR_ENV=1` and the scout fixture harness: exit 0, log has `watch S1; exit` and
   `orchestra scout S1: exit 0`.
10. `doctor` with `HERDR_ENV=1`: output has `herdr: in a herdr pane (ORCHESTRA_HERDR=auto)`; without: `herdr: not in a herdr pane (optional)`.

proof: `bash tests/herdr.sh`
proof: `bash tests/all.sh`
proof: `shellcheck -S warning bin/orchestra-worker tests/herdr.sh`

## Out of scope
- `examples/pi/*`, skills, docs and README (the orchestrator writes those).
- Any change to `watch`, `status`, `review`, `land` or exit codes.
- herdr agent naming, prompting other agents, or pane cleanup beyond the watch pane's own `; exit`.
