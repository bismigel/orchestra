---
id: Txx
title: Imperative title
status: draft            # draft | ready | done (done = a commit "Txx: …" on the base branch)
depends: none            # task ids, space-separated
delegation: worker       # worker | split | orchestrator
# ops profile only:
# risk: low              # low | medium | high (datapath, storage, edge, auth, deletes = high)
# rollback: how to undo it, in one line
---
## Goal
One paragraph: what the user (or the system) can do when this is done. The user-visible result, not the markup.

## Decisions
Everything the task needs decided, written as rules. Nothing left to the worker's judgment.

## Owns
- `path/that/exists`
- `path/to/new_file` (new)

## Touches
- `path/file`: the only change allowed (include existing tests that assert behaviour this task changes)

## Acceptance
- proof: `the command that proves it` (orchestra runs it on the exact code before landing; test names where possible)
- Orchestrator: checks a worker cannot do (screenshots, live checks)

## Out of scope
What not to do here, and which task does it instead.
