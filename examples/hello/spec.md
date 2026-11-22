# Task: hello (a smoke test for your orchestra setup)

**Delegation:** worker. Everything is decided below.

## Goal
Create `hello/greet.py` with a function `greet(name: str) -> str` that returns `"Hello, <name>!"`, and
`hello/test_greet.py` with tests for: a normal name, an empty name (returns `"Hello, there!"`), and surrounding
whitespace stripped (`"  Ada "` → `"Hello, Ada!"`).

## Paths you may change
`hello/` only.

## Acceptance
`python3 -m unittest discover -s hello -v` passes with 3 tests.

## Out of scope
Anything outside `hello/`. No dependencies.
