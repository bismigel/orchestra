---
name: ops-change
description: Infrastructure changes the GitOps way - preflight (blast radius, measured state, rollback), worker draft, rendered-diff review, PR, watch window, record. Covers new apps, upgrades, backup changes and restore drills, and secret rotation. Use for any cluster, network, DNS, backup, secret or host change, and to review an ops diff or an orchestra worker's ops run.
---

# ops-change

Follow "The change loop" in the guide printed by `orchestra-worker guide ops`, then pick
the checklist for the change type (new app, upgrade, backup change and restore drill, secret rotation).
Non-negotiables:
- Classify first: worker / split / orchestrator.
- `risk` and `rollback` set; current state measured with a quoted command (or refreshed host-side via
  `orchestra-worker scout <id> --spec <file> --state` when `ORCHESTRA_STATE_CMD` is configured).
- Review the rendered diff (`orchestra-worker diff <id> --rendered` when `ORCHESTRA_RENDER_CMD` is set) and answer
  every `risk_notes` item surfaced by `orchestra-worker review <id>`, not only the source diff. Use
  `orchestra-worker artifact <id>` when sharing a review bundle.
- Nothing applied directly, only through Git and the controller (or a human apply).
- Roll back on a failed watch, don't debug forward.
- Secret values never in the model's context; secret rotation is orchestrator-only.
- A backup is not done until a restore was tested.
