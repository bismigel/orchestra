---
name: ops-change
description: Make a change to infrastructure the GitOps way - ticket with risk class and rollback, preflight, worker draft, rendered-diff review, PR, watch window, record. Use for any cluster, network, DNS, backup or host change request.
---

# ops-change

Follow "The change loop" in `docs/ops-guide.md` in the orchestra repository (from this skill's folder: `../../../docs/ops-guide.md`). Classify first (worker / split / orchestrator), set `risk` and `rollback`, preflight before drafting, review the rendered diff, and never apply anything directly: changes reach live systems only through Git and the controller (or a human apply). Roll back on a failed watch, don't debug forward.
