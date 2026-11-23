# Ops guide: running infrastructure with orchestra

For the orchestrating agent on an infrastructure repository (`ORCHESTRA_PROFILE=ops`). Why: [proposals/0002](proposals/0002-ops-profile.md).
Assumes GitOps: desired state in Git, applied by a controller (Argo CD, Flux) or by a human (`tofu apply`). Nothing
in orchestra applies changes.

## Who does what
| Class | Work |
|---|---|
| `worker` | runbooks and docs from an outline; a new app from the template checklist; alert rules plus tests; dashboards; dependency bumps with changelog notes; validator fixes |
| `split` | manifests, Helm/Kustomize, backup config, secrets wired **by name**: you decide sizes, allow-lists, ports, versions; the worker writes them |
| `orchestrator` | network and datapath, storage and anything stateful, DNS and the edge, identity and access, secret values, incidents, anything that deletes |

Workers never get cluster, cloud, forge or secret-store credentials. Live reads (`kubectl get`, a `tofu plan` against
real state, metrics) are yours.

## Task fields (lint enforces them in this profile)
`risk: low | medium | high` (high = datapath, storage, edge, auth, deletes) and `rollback:` (one line: how to undo).

## The change loop
1. **Ticket**: what and why, risk class, rollback.
2. **Preflight**: blast radius, dependants, current state **measured** with a command (cite it).
   - What changes, for whom? What depends on it (search the repository and the live system)?
   - What is the current state (measure, quote the command)? Never rely on memory or docs alone.
   - What is the rollback, and has it been tried?
   - Can it be rehearsed? High risk: rehearse in staging, or the PR says why it can't be.
   - Which alert or probe will tell us it broke, and does it fire today if the thing is down?
3. **Draft**: the worker writes the diff and runs validators in its sandbox.
4. **Review**: read the **rendered** difference (`kustomize build`/`helm template` of base vs branch,
   diffed), not only the source diff. Check the repository's invariants line by line:
   - Rendered diff of every overlay touched.
   - No `:latest` or bare tags, digests copied not typed.
   - Requests and limits.
   - Probes (liveness never checks dependencies).
   - Network policy matches the decided allow-list exactly.
   - secrets referenced by name.
   - nothing stateful deleted or recreated.
   - The worker's `risk_notes` answered.
   - A guard or probe must be shown to fail when it should: "a check that cannot fail is worthless".
5. **PR**: CI runs the same validators. A human merges high-risk changes.
6. **Watch**: after apply, controller sync and health, alerts, probes and logs for a fixed window. A failed check
   means roll back, not debug forward.
7. **Record**: current-state docs; a decision record if something was decided; a lessons line if anything surprised.

## Change types
Each is a short checklist. Start from the change loop above and give these loop steps the most attention.

### New app
- Namespace and admission level.
- Default-deny network policy plus explicit egress.
- Secrets through the secrets operator, referenced by name.
- Requests and limits; readiness and liveness (liveness never checks dependencies).
- Pinned digests.
- The controller application.
- Backups, or an explicit "no backups" with the reason.
- Monitoring and alerts.
- The edge route.
- The repository's own template checklist wins over this list.
- Loop steps that matter most: ticket and preflight (the decisions), then review.

### Upgrade
- Read the changelog between versions for breaking changes and migrations.
- Bump in staging first, with a watch window.
- Then production, with its own watch window.
- Note the version and anything learned.
- Loop steps that matter most: preflight (read every version in between) and watch.

### Backup change and restore drill
- Restore the latest backup into a scratch target.
- Check row counts or files against the source.
- Time it, and record the date, size, duration and what was compared.
- An untested backup is a hope.
- Loop steps that matter most: ticket/preflight (what and why) and record.

### Secret rotation (orchestrator only)
- Inventory every consumer of the secret first (search config, the secret store, the cluster, hosts).
- Mint the new credential.
- Propagate to every consumer.
- Verify each one actually uses it (a real call, an archive, a login).
- Only then revoke the old one.
- Values never enter the model's context: move them with helpers that don't print, compare by fingerprint.
- Loop steps that matter most: preflight (inventory and rollback) and watch (verify each consumer).

## Incidents
Stabilise first (roll back the last change if it correlates). Gather evidence before theories: events, logs, metrics,
recent changes. One hypothesis at a time, each verified with a command before it is stated. Mitigate, then fix through
Git. Write it up: timeline, cause, the guard that would have caught it. Incidents are orchestrator work and are never
delegated to workers.

## Integrations (least privilege)
| Area | Use | Access |
|---|---|---|
| Kubernetes | MCP server or `kubectl` with allow-listed read verbs | read-only account |
| GitOps controller | status, diff | read; changes through Git |
| Metrics and alerts | Prometheus-compatible API, Alertmanager, Grafana | read |
| Logs | Loki or equivalent | read |
| Forge | PRs, issues, CI status | PRs and comments only |
| Edge and DNS | provider API or MCP | read; changes through IaC PRs |
| Secrets | helpers that don't print, never an MCP | never in context |
| Docs | fetch upstream changelogs and references | read |
