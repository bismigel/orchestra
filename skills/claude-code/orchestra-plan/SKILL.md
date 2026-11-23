---
name: orchestra-plan
description: Run a planning session for a new project or major phase - brief, decisions, scope, architecture, wireframes, and a task board of worker-ready tasks. Use when the user wants to plan, scope, design or kick off a project ("plan this", "MVP", "wireframes", "set up the board") before any code is delegated.
---

# orchestra-plan

Lead the planning session in the guide printed by `orchestra-worker guide planning` (follow it step by step; the
templates are in the directory printed by `orchestra-worker guide templates`). Essentials:

- Five phases, each ending in a checkpoint the human approves: **Discover** (brief) → **Decide** (numbered decisions,
  scope, architecture) → **Design** (HTML wireframes with numbered notes) → **Decompose** (tasks, board, waves) →
  **Check** (`orchestra-plan` ends with `orchestra-refine all` and `orchestra-task lint` passing).
- Ask the human only what they alone know: at most four questions per round, each with a recommended answer. Propose
  everything else and record it in `docs/plan/decisions.md`.
- The planning pack in the repository is the state: resume from the files, never from memory.
- Every hard rule (data, privacy, security, money) must be testable, and every task must leave no judgment call open.
- Finish by telling the human what was decided, what still needs them, and the first wave ready for workers.
