---
name: ops-preflight
description: Before an infrastructure change - measure current state, find dependants and blast radius, define rollback and the alert that would catch a break. Use before drafting or merging any medium or high risk ops change.
---

# ops-preflight

Follow the `ops-preflight` playbook in `docs/ops-guide.md` in the orchestra repository (from this skill's folder: `../../../docs/ops-guide.md`). Every fact about current state comes from a command you ran and quote, never from memory or docs alone. High-risk changes are rehearsed in staging or the PR says why not.
