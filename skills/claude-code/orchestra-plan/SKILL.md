---
name: orchestra-plan
description: Plan a new project or major phase (brief, decisions, scope, architecture, wireframes, a board of worker-ready tasks), or refine existing tasks until they are ready for workers. Use when the user wants to plan, scope, design or kick off a project ("plan this", "MVP", "wireframes", "set up the board"), or to refine tasks, before launching workers or after decisions change.
---

# orchestra-plan

Lead the planning session in the guide printed by `orchestra-worker guide planning` (follow it step by step; the
templates are in the directory printed by `orchestra-worker guide templates`). Essentials:

- Five phases, each ending in a checkpoint the human approves: **Discover** (brief) → **Decide** (numbered decisions,
  scope, architecture) → **Design** (HTML wireframes with numbered notes) → **Decompose** (tasks, board, waves) →
  **Check** (every task refined and `orchestra-task lint` passing).
- Ask the human only what they alone know: at most four questions per round, each with a recommended answer. Propose
  everything else and record it in `docs/plan/decisions.md`.
- The planning pack in the repository is the state: resume from the files, never from memory.
- Every hard rule (data, privacy, security, money) must be testable, and every task must leave no judgment call open.
- Finish by telling the human what was decided, what still needs them, and the first wave ready for workers.

**Refine** (one task, a wave or all; before launching workers, after a decision changes, or when a worker came back
with open questions): `orchestra-task lint <ids> --strict`, scout each task beyond a few files, then the judgment half
of the definition of ready and the lessons file: `orchestra-worker guide planning --section refine`. Report per task
ready / not ready and the decisions still needed, each with a recommended answer; set `status: ready` only when it is.
