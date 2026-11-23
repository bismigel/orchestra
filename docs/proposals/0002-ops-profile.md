# Proposal 0002: an `ops` profile for running infrastructure

Status: **implemented in 0.2.0** (2026-11-22)
Update 0.5.0: the eight skills became two (ops-change, ops-incident); the playbooks are change types in docs/ops-guide.md.

## Why a separate profile
Software tasks change code that is reviewed and then shipped. Operations tasks change **live systems**: a cluster, a
network, DNS, backups, secrets. The unit of work is a *change* with a blast radius, the evidence is the state of the
system, and a mistake is an outage, not a failing test. The orchestrator/worker split still pays off, but the lines
move: far more is judgment, and workers must never hold the keys to production.

The profile targets GitOps-style setups (desired state in Git, applied by a controller such as Argo CD or Flux, or by
a human running `tofu apply`), which is what makes delegation safe at all: a worker can only ever produce a diff.

## Delegation in ops
| Class | Typical work |
|---|---|
| **worker** | runbooks and docs from a decided outline; scaffolding a new app from a template checklist; alert rules plus their unit tests; dashboards; dependency-bump PRs with changelog notes; lint and validation fixes |
| **split** | Kubernetes manifests, Helm or Kustomize changes (the orchestrator decides resources, limits, network allow-lists; the worker writes them); backup configuration; wiring secrets **by name** |
| **orchestrator only** | network and datapath (CNI, VPN, firewall, routing), storage and anything stateful, DNS and the edge, identity and access, secret values and rotation, incidents, anything that deletes |

Workers in this profile get **no cluster, cloud or forge credentials, ever**. Their sandbox has the repository and
read-only validators: `kustomize build`, `helm template`, `kubeconform`, `promtool test rules`, `tofu validate`,
`shellcheck`, policy checks (Kyverno/Conftest). Anything that needs live access (a plan against real state, a
`kubectl get`) is run by the orchestrator.

## The change loop
1. **Ticket.** What and why, the risk class (low / medium / high: high = datapath, storage, edge, auth, deletes),
   and the rollback.
2. **Preflight** (orchestrator). What could break, what depends on it, current state measured (not remembered).
   High-risk changes are rehearsed in staging first, or the PR says why they cannot be.
3. **Draft.** Worker (for `worker`/`split` parts) produces the diff and runs the validators in its sandbox.
4. **Review.** The orchestrator reads the **rendered** difference (for example `kustomize build` of base vs branch,
   diffed), not only the source diff, and checks invariants the repository documents (network rules, "never delete"
   rules, ownership of fields).
5. **Pull request** on the forge; CI runs the same validators. A human merges high-risk changes.
6. **Watch.** After apply: controller sync status, health, alerts, probes, logs, for a set window. Roll back on a
   failed check, don't debug forward.
7. **Record.** Current-state docs updated; a decision record if something was decided; one line in the lessons file
   if the change surprised anyone.

## Skills the profile ships (orchestrator side)
| Skill | What it encodes |
|---|---|
| `ops-change` | the loop above, risk classes, rollback-first thinking |
| `ops-preflight` | blast-radius questions, dependency lookup, measuring current state, staging rehearsal |
| `ops-review` | rendered-manifest diff, invariant checks, "a check that cannot fail is worthless" |
| `ops-incident` | triage: gather evidence, one hypothesis at a time, verify before asserting, mitigate, write up |
| `ops-new-app` | the template checklist: namespace, network policy, secrets via an operator, probes, requests/limits, pinned digests, backups or an explicit "no backups" |
| `ops-upgrade` | version bumps: changelog and breaking-change reading, staging first, watch window |
| `ops-secret-rotation` | inventory every consumer before rotating, mint new, propagate, verify each consumer, then revoke; values never enter the model's context |
| `ops-backup-drill` | restore into a scratch target and check it, on a schedule |

## Recommended integrations (least privilege)
Prefer **read-only** access for the orchestrator and make writes go through Git. Where an MCP server would grant
broad write access, use a CLI with an allow-list instead.

| Area | Integration | Access |
|---|---|---|
| Kubernetes | a Kubernetes MCP server or `kubectl` with an allow-listed set of read verbs (get, describe, logs, events, top) | read-only service account |
| GitOps controller | Argo CD or Flux API/CLI: app status, sync state, diff | read; sync only through Git |
| Metrics and alerts | Prometheus-compatible query API, Alertmanager; a Grafana MCP server for dashboards | read |
| Logs | Loki/Elasticsearch query | read |
| Forge | GitHub/Gitea/Forgejo MCP or CLI: PRs, issues, CI status | write PRs and comments only |
| Edge and DNS | the provider's MCP or API (for example Cloudflare's) for DNS, tunnels, access logs | read; changes via IaC PRs |
| Secrets | **no MCP**: small helpers that hand a value to a process without printing it | never in context |
| Docs | a docs-fetch tool for upstream changelogs and references | read |

## How it plugs in
- `ORCHESTRA_PROFILE=ops` in the repository's `.orchestra/config.env` selects `prompts/worker-ops.md` (no-credentials
  rules, validators to run, rendered-diff expectations) and the ops skills.
- Ops tasks use the same task file format plus `risk:` and `rollback:` front-matter fields; `orchestra task lint`
  enforces them in this profile.
- Nothing in orchestra applies changes. Applying stays with your controller or a human.

## Open questions
1. Should `ops` workers be allowed a read-only kubeconfig for a **staging** cluster to run server-side dry-runs?
2. One combined repository profile or separate repositories for software and ops (most homelabs keep both)?
3. Which validators should be mandatory per change type (manifests, IaC, alerts, scripts)?
