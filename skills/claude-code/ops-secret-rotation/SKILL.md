---
name: ops-secret-rotation
description: Rotate a credential safely - inventory all consumers, mint, propagate, verify each consumer, then revoke; values never in model context. Use when a key, token or password must be rotated or was exposed.
---

# ops-secret-rotation

Follow the `ops-secret-rotation` playbook in `docs/ops-guide.md` in the orchestra repository (from this skill's folder: `../../../docs/ops-guide.md`). Orchestrator only. Never print a secret: move values with helpers, compare by fingerprint, and revoke the old credential only after every consumer is verified on the new one.
