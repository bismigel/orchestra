---
id: T1
title: Pin review and land to a candidate snapshot
status: ready
depends: none
delegation: split
---
## Goal
After `orchestra-worker prove` passes, the worktree's exact state is recorded in `.orchestra/candidate.json`.
`review` and `land` then compare against that snapshot: if the worktree changed after the candidate was made (the
orchestrator's own small fixes, or a rebase onto a moved base), the orchestrator sees exactly what changed, and
`land` still re-proves the new tree before publishing. No candidate, or no drift, means today's output unchanged.

## Decisions
- The record is `.orchestra/candidate.json`, one per task worktree, overwritten on each successful prove. Fields:
  `task`, `run`, `base`, `base_commit`, `tree`, `spec`, `spec_tree`, `at`.
  - `run` = the number of `run-*.jsonl` files in `.orchestra/runs/` (the same convention `run` uses to assign the
    next number), or `null` when there are none.
  - `base` = the `ORCHESTRA_BASE` string; `base_commit` = `git rev-parse "$ORCHESTRA_BASE^{commit}"`, or `null` if
    it does not resolve (never fail the write over this).
  - `tree` = the `work_tree()` hash; `spec` = the `spec_file()` path or `null`; `spec_tree` = `git hash-object` of
    that spec file, or `null`; `at` = ISO 8601 UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`).
- `prove_all` writes the candidate when every check passes (exit 0), using its own `$tree` (the tree the proofs bound
  to), so `land` also ends up with a fresh candidate after its internal `prove_all`. `prove --manual` writes it too,
  with the `work_tree()` it already computed. Writing is atomic: temp file in the same directory, then `mv`.
- `review` reads `.orchestra/candidate.json`. Treat an unreadable, malformed, non-dict, or different-`task` record as
  "no candidate". When present, add the candidate line right after the existing `task · run …` header:
  `candidate: run 2, base f072b7f1a2b3, tree 9f3c1a2b4d5e` (base and tree truncated to 12 chars).
  When the live tree (the `--tree` value already passed in) differs from `candidate.tree`, add the line
  `candidate drift: worktree differs from the candidate tree`, then the stat of
  `git -C <wt> --no-pager diff --stat=100 <candidate.tree> <live-tree>` (no generated-file exclusion), indented the
  same way `land` indents its `changes:` stat. No candidate → exactly today's output.
- `review --json` gains one top-level key `candidate`: `null`, or an object with the record fields plus
  `drift` (bool) and `drift_stat` (the stat text, or `""`). Update the exact key-set assertion in tests/review.sh.
- `land` reads candidate.json right before its `prove_all` (i.e. after rebase and squash). When present and
  `candidate.tree` differs from the current `work_tree()`, print `candidate drift: publishing a tree that differs
  from the candidate` followed by the same stat block, then proceed unchanged (land already re-proves).
- Writing candidate.json must not change the tree hash: it lives under `.orchestra/` (already excluded).
- No lock: the existing one-run-per-task guard (`run.json` pid) already prevents concurrent writers.
- `clean.py` also uses the word "candidate" (for a worktree); that is a different thing. Do not touch clean.py.
- `CHANGELOG.md` gets an entry (CONTRIBUTING.md requires it for a behaviour change).

## Owns
- `bin/orchestra-worker`
- `lib/review.py`
- `docs/proofs.md`
- `docs/orchestrator-guide.md`
- `tests/candidate.sh` (new)
- `CHANGELOG.md`

## Touches
- `tests/review.sh`: update the `--json has every key` assertion (line ~142) to include `candidate`; add no other
  changes there.
- `tests/run.sh`: the prove/land fixtures now exercise the candidate write; verify they still pass and change them
  only if the new output breaks an assertion.

## Acceptance
- proof: `shellcheck -x -S warning bin/orchestra-worker bin/orchestra-task lib/harness/*.sh install.sh tests/*.sh tests/fixtures/*.sh`
- proof: `tests/all.sh`

Required test rows (worker writes these in `tests/candidate.sh`; offline, no model calls; chmod +x the suite):
1. prove (all pass) writes candidate.json; `tree` equals `work_tree()` at prove time; the file is valid JSON.
2. review with no candidate prints no candidate line and `--json` reports `candidate == null` (backward compatible).
3. review with a candidate and an unchanged tree prints the candidate line, no drift line, `drift == false`.
4. review with a candidate and a changed tree prints the drift line and the stat; `drift == true`, `drift_stat`
   non-empty.
5. land with a changed tree since the candidate prints the drift notice, still lands, and re-proves (the landed
   commit's tree differs from the old candidate tree).
6. writing candidate.json does not invalidate the next prove (the proof is reused: `(proven)`).

## Out of scope
- No four-record store, no scheduler, no daemon, no manifest language (see the earlier critique). Just the candidate
  record and drift surfacing.
- `spec_tree` in the candidate is informational only; no change to how proofs pin check definitions (they already
  re-match on the check command string).
