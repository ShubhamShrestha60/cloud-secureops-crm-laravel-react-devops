# Architecture

The system is a single staging-shaped environment that looks like production in
its delivery path, security boundaries, and operational failure modes. It was
decommissioned on 2026-11-04; this document describes the as-built design.

---

## 1. Component inventory

| Layer | Component | Managed by | Notes |
|---|---|---|---|
| Network | VPC `10.0.0.0/16` | Terraform | 2 AZs in staging; public + private subnets |
| Egress | Internet Gateway, single NAT Gateway | Terraform | NAT is a fixed hourly cost |
| Compute | EKS 1.32 control plane | Terraform (EKS module) | public endpoint enabled |
| Compute | Managed node group | Terraform | 3× `t3.small`, 30 GB gp3 |
| Add-ons | VPC CNI, CoreDNS, kube-proxy, EBS CSI, AWS LB Controller | Terraform | IRSA where needed |
| Registry | ECR, 2 private repos | Terraform | immutable tags, scan-on-push, lifecycle 20 |
| Data | RDS PostgreSQL 16, `db.t3.micro` | Terraform | private, encrypted, 1-day backups in staging |
| Secrets | AWS Secrets Manager | Terraform + manual app secret | DB secret generated; app secret holds `APP_KEY`/URLs |
| Edge | ALB | AWS LB Controller from Ingress | not Terraform-managed |
| Edge | ACM certificate | manual | must be in `ap-south-1`, same as ALB |
| Edge | Route 53 record | manual | hostname → ALB |
| Edge | WAFv2 REGIONAL ACL | Terraform | managed rules + per-IP rate limit |
| Delivery | GitHub Actions CI + Release | repository | OIDC, no static keys |
| Delivery | ArgoCD | bootstrap script | pull-based, auto-sync, self-heal |
| Workloads | Helm chart | ArgoCD | Deployments, Services, Job, HPA, PDB, Ingress, ExternalSecret |
| Observability | CloudWatch alarms + SNS | Terraform | no confirmed subscriber in the original run |

---

## 2. Request path

### Browser request

```text
Client
  → Route 53 (hostname)
  → ALB (WAF associated)
  → listener :443 (ACM cert), :80 redirects to :443
  → Ingress rules
      /api  → backend Service :80 → pod :8080 (nginx + php-fpm)
      /     → frontend Service :80 → pod :8080 (nginx + SPA)
```

The frontend is a static SPA. On EKS it does not proxy `/api`; the ALB routes
`/api/*` directly to the backend. The nginx proxy in `frontend/nginx.conf` is a
local-compose fallback and uses a resolver + variable upstream so nginx can start
even when the `backend` DNS name does not exist.

### Deploy path

```text
git push main
  → release.yml: OIDC → build locally → Trivy gate → push sha-* to ECR
  → commit new tag in values-staging.yaml
  → ArgoCD sees commit
  → sync wave -10: ExternalSecret
  → sync wave -5: migration Job
  → wave 0: backend/frontend Deployments
  → ALB controller reconciles Ingress
```

No CI job holds cluster credentials. That is the central security property of
the pull-based design.

---

## 3. Trust boundaries

| Boundary | Control |
|---|---|
| Internet → ALB | WAF managed rules, per-IP rate limit, TLS only |
| ALB → pods | Security groups; target type `ip`; only ports 8080 |
| Pods → RDS | Private subnets, RDS SG allows only the node/pod SG |
| CI → AWS | OIDC trust restricted to repository/ref; ECR-only role |
| Pods → Secrets Manager | IRSA role for the External Secrets service account |
| Nodes → AWS APIs | IRSA per add-on instead of broad node role permissions |
| Git → cluster | ArgoCD project allowlist; no developer kubeconfig in CI |

The largest residual risk in the original setup was ArgoCD's private-repo
credential. It used a GitHub PAT stored as a Kubernetes Secret. A public
portfolio repo would remove that need entirely.

---

## 4. Kubernetes reconciliation

- ArgoCD Application: `argocd/apps/staging.yaml`.
- Automated sync with `prune: true`, `selfHeal: true`.
- `CreateNamespace=true`, `ServerSideApply=true`.
- Retry: 5 attempts, exponential backoff.

Sync waves inside the chart:

| Wave | Resource | Why |
|---|---|---|
| `-10` | ExternalSecret | Secret must exist before workloads |
| `-5` | Migration Job | Schema must be ready before new pods serve |
| `0` | Deployments / Services / HPA / PDB / Ingress | Application rollout |

`selfHeal` means manual `kubectl edit` changes are reverted. The correct debugging
loop is: inspect live state, then fix Git. Emergency `rollout undo` is possible
but can be overwritten by the next sync.

ArgoCD status showed a cosmetic `Degraded` at times even when pods were healthy.
The operational rule is to corroborate with pod readiness and HTTP checks, not
the health flag alone.

---

## 5. Data and secrets

- Database is RDS PostgreSQL in private subnets.
- Credentials are generated into Secrets Manager by Terraform.
- App-level values (`APP_KEY`, `APP_URL`, `FRONTEND_URL`, CORS) live in a
  separate Secrets Manager secret.
- External Secrets maps both into a Kubernetes Secret consumed by the backend.
- The migration Job runs with the same secret but `SKIP_MIGRATIONS=true` on the
  Deployment prevents app pods from racing migrations.
- `APP_KEY` rotation is not routine: it would require re-encrypting any data
  encrypted with the old key.

---

## 6. Failure domains

| Failure | Blast radius | Detection | Mitigation |
|---|---|---|---|
| Single pod crash | one replica | readiness, restarts | 2 replicas + PDB |
| Node loss | pods on that node | node status, events | managed node group replaces node |
| AZ loss (staging uses 2) | half the nodes | alarms, target health | multi-AZ subnets; no staging SLA |
| RDS failure | writes/reads | health 500, RDS status | backups, restore drill |
| Bad image | new pods fail | Trivy gate, CrashLoop | immutable tags, rollback via Git |
| Bad migration | schema break | Job failure | Job runs before rollout; restore |
| Secret sync failure | new pods cannot start | `CreateContainerConfigError` | ESO retry, wave ordering |
| ALB/controller failure | no ingress | 5xx/timeout | controller logs, re-sync |
| ArgoCD down | no new deploys | sync age | existing pods keep running |
| State bucket loss | Terraform blind | init/plan errors | restore state before destroy |

The design is HA-shaped at the pod and AZ level, but it is still a **single
environment**. There is no blue/green or canary. A bad migration is the most
dangerous change because it can affect all replicas at once.

---

## 7. Observability model (and its gaps)

What existed:

- Liveness `/up` and readiness `/api/v1/health`.
- Container logs to stdout (`LOG_CHANNEL=stderr`).
- CloudWatch alarms for RDS CPU, RDS free storage, and ALB target 5xx.
- SNS topic for alarm actions.

What did not work as intended:

- No metrics-server → HPA could not read CPU; `kubectl top` unavailable.
- No Prometheus/Grafana → no dashboards or history.
- No centralized logs → logs vanish with pods.
- `alert_email` empty → no confirmed subscriber, so alarms did not notify anyone.
- No tracing or synthetic uptime checks.

The correct claim is: **health endpoints and alarm definitions existed; a complete
observability path did not.** The remediation backlog is in `SKILLS_EVIDENCE.md`.

---

## 8. Cost shape

Approximate staging burn from the observed period:

- Awake: ~$199/month.
- Asleep (nodes zero, RDS stopped): ~$100/month.

The fixed-cost floor is the important lesson: EKS control plane, NAT, ALB/WAF,
and storage bill even when no pods run. Sleeping reduces compute, not the floor.
For long pauses, snapshot and destroy. See the cost chapter and teardown chapter
for the exact order.

---

## 9. Design trade-offs

| Decision | Benefit | Cost |
|---|---|---|
| Scan-before-push in CI | registry only contains scanned bytes | no build attestation/SBOM |
| Immutable sha tags | exact deploy identity | tag churn; no mutable `latest` |
| Pull-based ArgoCD | no cluster creds in CI | ArgoCD becomes critical infrastructure |
| Single NAT | cheaper | egress is a single-AZ failure domain |
| 2 AZs in staging | cheaper than 3 | no full AZ fault tolerance |
| External Secrets | no secrets in Git | extra controller and IRSA dependency |
| Helm + ArgoCD | declarative, auditable | two layers to debug |
| `selfHeal: true` | drift correction | manual hotfixes are reverted |

These are deliberate staging trade-offs, not production claims.
