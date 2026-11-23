# Proposal 0004: closing the gaps around the loop

Status: **implemented in 0.7.0** (2026-11-23)

## Assessment
The core loop (spec, scout, run, review, prove, land) worked: 0.5 and 0.6 were built with it, about $0.05 per run.
The gaps were around it.

| # | Gap or pitfall | Evidence | 0.7 |
|---|---|---|---|
| 1 | Skills referred to guides as `../../../docs/…` "from this skill's folder", but the folder is a symlink | read literally, the path is `~/docs` | `orchestra-worker guide <name>` prints the real path; skills use it; `tests/docs.sh` forbids `../../../` |
| 2 | Docs drift: the same commands described in skill, guide, README and the pi extension | fixed by hand three times in one week | `tests/docs.sh`: every `orchestra-worker <cmd>` in the docs exists, the main skill covers the CLI, links resolve |
| 3 | Two runs on one task could start at once and overwrite each other's state | `run.json` was simply rewritten | a second run on a live task is refused (exit 2) |
| 4 | Stopping `orchestra-worker` left the worker running until its timeout | reproduced on 0.6.0: SIGTERM killed the script, the worker kept going | the worker is a supervised job; TERM and INT stop it (exit 130) |
| 5 | Only the timeout bounded a looping worker's spend | | `ORCHESTRA_MAX_COST` (exit 5) |
| 6 | `clean` deleted each task's runs, cost and questions | a project's real spend was unknowable after cleanup | `clean` archives to a ledger first; `orchestra-worker history` |
| 7 | The lessons loop did not happen | 17 tasks, 1 line in the lessons file | `orchestra-worker lessons <id>` drafts lines; `review` shows `lessons N spec gap(s)` |
| 8 | Spec proofs unused | 0 of 63 tasks in one repository had a `proof:` line, so `land` proved only the gate | lint warns `L8 no proof: line`; `--strict` |
| 9 | No setup check: a broken key or sandbox surfaced as a failed run | | `orchestra-worker doctor` (key by fingerprint only) |
| 10 | `land` could not land on a protected base | landing orchestra itself needed a manual cherry-pick and a PR | `land --pr` / `ORCHESTRA_LAND=pr` |
| 11 | The pi extension lived outside the repository and drifted: its review dumped up to 40 KB of diff, its run returned progress lines, its land prompt hard-coded one repository and pushed by hand | | `examples/pi/orchestra.ts` (card only, digest by default, scout/status tools, `pr`), `examples/pi/prompts/land.md` |

## Not done
- More harness adapters (issue #3): need real event logs from each tool.
- Scout and lint still do not run each other: `refine` asks for both.
