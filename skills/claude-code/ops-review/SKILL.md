---
name: ops-review
description: Review an infrastructure diff or worker run - rendered manifest diff, invariants, pinned digests, limits and probes, network allow-lists, nothing stateful deleted. Use when reviewing an ops PR or an orchestra worker's ops report.
---

# ops-review

Follow the `ops-review` playbook in `docs/ops-guide.md` in the orchestra repository (from this skill's folder: `../../../docs/ops-guide.md`). Diff the rendered output (kustomize/helm) of base vs branch, check the repository's invariants line by line, answer every item in the worker's risk_notes, and prove any new guard or probe fails when it should.
