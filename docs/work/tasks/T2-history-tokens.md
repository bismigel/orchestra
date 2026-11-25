---
id: T2
title: History and the ledger keep token counts, not only cost
status: done
depends: none
delegation: worker
---
## Goal
`orchestra-worker history` shows how many tokens each task used next to its cost, and the total, and the ledger that
`clean` writes keeps those counts, so a task archived today still reports its tokens next year. Today the per-run
`runs/run-N.usage.json` already holds `input`, `output`, `cache_read` and `reasoning`, but `history.run_records`
keeps only `responses` and `cost`, so archiving drops the tokens.

## Decisions
- `lib/history.py`, `run_records`: each run record gains `input`, `output`, `cache_read`, `reasoning`, each
  `int_or_none(usage.get(<key>))` (so a usage file without the key gives `null`, never 0), and `tokens` =
  `input + output + cache_read` when all three are not None, else None. `reasoning` is kept but not added to `tokens`.
- `task_record` and `scout_record` gain `tokens`: the sum of the runs' `tokens` when there is at least one run and every
  run's `tokens` is not None; otherwise None. Add a helper `total_tokens(runs)` next to `total_cost`.
- Ledger lines written before this change have no token fields. They stay valid (`valid_record` must not require
  them) and show as unknown.
- New `fmt_tokens(n)`, exactly: None → `"-"`; `n < 1000` → `str(n)`; `n < 999_500` → `"%dk" % int(n / 1000 + 0.5)`;
  else `"%.1fM" % (n / 1_000_000)`.
- Table: a `TOKENS` column right after `COST`, value `fmt_tokens(row.get("tokens"))`. Header order becomes
  `TASK KIND RUNS COST TOKENS STATUS BLOCKING ASSUMED WHEN`.
- `totals`: add `tokens` = the sum of every row's `tokens` that is not None (0 when none), and `tokens_unknown` = the
  number of rows with at least one run whose `tokens` is None. The JSON `total` object gains both keys.
- Text total line: `total: %d tasks, %d runs, $%.4f, %s tokens` with `fmt_tokens(total["tokens"])`, followed by
  ` (%d without token data)` only when `tokens_unknown > 0`.
- Nothing else changes: cost formatting, existing JSON keys, row order, the malformed-line handling.
- Docs: in `README.md` change "every task's runs and cost" to "every task's runs, tokens and cost" (both places);
  in `docs/orchestrator-guide.md` line ~105, "shows live and archived tasks" sentence: mention tokens next to cost.

## Test rows (`tests/history.sh`; add these, keep every existing check)
| fixture | expected |
|---|---|
| run usage `{"responses":4,"input":1000,"output":200,"cache_read":50000,"reasoning":30,"cost":0.01}` | run `tokens` 51200, `reasoning` 30 in `--json` |
| run usage `{"responses":2,"cost":0.02}` (no token keys) | run `input`/`output`/`cache_read`/`tokens` all `null` in `--json` |
| a task with one run of each kind above | row `tokens` is `null`; its TOKENS cell is `-` |
| a task whose only run has `{"responses":1,"input":10,"output":5,"cache_read":0,"cost":0.001}` | row `tokens` 15, cell `15` |
| an old ledger line with runs `[{"n":1,"exit":0,"secs":5,"responses":3,"cost":0.1}]` and no token fields | listed, TOKENS `-`, counted in `tokens_unknown` |
| `fmt_tokens` via `python3 -I -c 'import sys; sys.path.insert(0,"lib"); import history as h; print(...)'` | None→`-`, 0→`0`, 999→`999`, 1000→`1k`, 1499→`1k`, 1500→`2k`, 999499→`999k`, 999500→`1.0M`, 121000000→`121.0M` |
| text total with at least one unknown row | ends with `tokens (N without token data)` where N is the count of such rows |
| negative: every check that existed before this task | still passes unchanged |

## Owns
- `lib/history.py`
- `tests/history.sh`

## Touches
- `README.md`: the two "runs and cost" phrases only
- `docs/orchestrator-guide.md`: the one history sentence only
- not `CHANGELOG.md` (the orchestrator writes it)

## Acceptance
- proof: `bash tests/history.sh`
- proof: `bash tests/docs.sh`
- proof: `bash tests/clean.sh`
- Orchestrator: `orchestra-worker history` in `~/projects/easyshortlist` (old ledger lines show `-`, live runs show tokens).

## Out of scope
Recording tokens anywhere else (`summary`, `review`, the end card), and the pi extension.
