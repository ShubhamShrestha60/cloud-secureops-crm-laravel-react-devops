# Part I — Understanding the project, Chapters 1–2

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

## Chapter 1 — Project overview

### 1.1 What this is

SecureOps CRM is a contact-management web application ("Command Center":
contacts pipeline, security audit log, analytics) with two codebases and a
complete production hosting stack, all in one repository:

- `backend/` — Laravel 12 (PHP 8.3) JSON API, Sanctum token auth, Postgres.
- `frontend/` — React 18 + Vite SPA served by nginx.
- `infra/terraform/` — AWS VPC, EKS 1.32, RDS Postgres 16, ECR, IAM/OIDC,
  ALB Controller, External Secrets, WAF, CloudWatch alarms.
- `charts/secureops/` — Helm chart (Deployments, Services, HPA, PDB,
  migrate Job, ExternalSecret, ALB Ingress).
- `argocd/` — GitOps Project + staging Application, ClusterSecretStore.
- `.github/workflows/` — `ci.yml` (fast PR checks) and `release.yml`
  (gated build → scan → push).
- `ops/` — executable sleep/wake scripts; `docs/` — runbooks.

FACT: there is exactly **one live environment**, named `staging`
(`secureops-staging` cluster, `secureops-staging` namespace). Files named
`*prod*` (`prod.tfvars`, `values-prod.yaml`) are retained templates for a
second environment that was deliberately never built (cost decision, Ch. 12).
Do not read "staging" as "throwaway": it carries production properties
(TLS, WAF, immutable images, backups, gates) and serves the public demo.

### 1.2 Deployment model

**GitOps pull model.** Nothing pushes to the cluster. CI builds images and
stops at the registry (ECR). ArgoCD, *inside* the cluster, converges cluster
state toward git state. Consequences worth internalizing now (full treatment
in Ch. 5–6):

- Rollback = `git revert` the image-tag line. No `kubectl rollout undo`.
- The cluster needs no CI credentials; CI needs no cluster credentials.
- If ArgoCD is down, running workloads are unaffected — only *changes* stop.

### 1.3 Problems this stack solves (and for whom)

| Problem | Solution in this repo |
|---|---|
| "Works on my machine" deploys | Versioned immutable images; same artifact tested, scanned, shipped |
| Secret sprawl (`.env` in git/chat) | Secrets Manager → External Secrets; only ARNs/IDs in git |
| Unreviewed production changes | PR checks + manual tag pinning + ArgoCD diff before sync |
| Vulnerable dependencies reaching users | Trivy gate *before* push (Ch. 6 explains why order matters) |
| 3 AM "is it down?" | Health probes at three levels, alarms, runbooks |
| Demo link must survive on a budget | Sleep/wake system (~$100/mo asleep, Ch. 11) |

### 1.4 Technology inventory (with versions pinned in repo)

| Layer | Choice | Pinned in |
|---|---|---|
| Language/runtime | PHP 8.3 (FPM), Node 20 (build) | `backend/Dockerfile`, `frontend/Dockerfile`, `composer.json: platform 8.3` |
| Frameworks | Laravel 12, React 18 + Vite | `composer.json`, `frontend/package.json` |
| DB | RDS Postgres 16, `db.t3.micro` | `infra/terraform/rds.tf` |
| Orchestration | EKS 1.32, 3× `t3.small` | `staging.tfvars`, `eks.tf` |
| Registry | ECR, immutable tags, keep-20 | `ecr.tf` |
| IaC | Terraform `>=1.6`, AWS provider `~>5.60` | `versions.tf`, `.terraform.lock.hcl` |
| Delivery | Helm chart + ArgoCD v3.5.3 | `charts/`, `argocd/` |
| Ingress | AWS LB Controller 1.7.2, ALB | `addons.tf` |
| Secrets | Secrets Manager + ESO 0.10.4 | `rds.tf`, `eso-irsa.tf`, `clustersecretstore.yaml` |
| CI/CD | GHA: Buildx v6, Trivy action v0.36.0 | `.github/workflows/` |
| TLS | ACM (DNS validation) | Ch. 7; cert ARN in `values-staging.yaml` |
| WAF/alarms | WAFv2 managed rules, 3 CW alarms + SNS | `waf.tf`, `alarms.tf` |

### 1.5 Implemented vs. missing (honest ledger)

Implemented: everything above, plus Dependabot, SARIF upload, sleep/wake
automation, tested backup/restore, quarantine cleanup of bad images.

Deliberately missing: second prod environment, SSO for ArgoCD (planned,
Ch. 12), HSTS header, metrics-server/Prometheus (note: `kubectl top` fails —
capacity insight comes from requests/limits math), PITR beyond 1-day staging
retention, `latest`-tag deletion policy review, load testing evidence.
Each missing item has a cost/effort reason, not an oversight story — Ch. 12
turns this list into a prioritized backlog.

---

## Chapter 2 — Repository tour

### 2.1 Layout and responsibilities

```
.github/workflows/ci.yml        PR checks only. No AWS credentials. Must stay <5 min.
.github/workflows/release.yml   Build→scan(gate)→push to ECR via OIDC. Never touches cluster.
.github/dependabot.yml          Weekly bumps: actions, docker (both), terraform.
Dockerfile(s): backend/ frontend/   Prod images. Compose never uses them for prod.
docker-compose.yml              DEV ONLY. Local loop + onboarding. Never prod (says so, line 1-3).
.env.example / backend/.env.example / frontend/.env.example
                                Committed templates. Real .env never committed (gitignored).
Makefile                        up/down/logs/ps/seed + helm-lint + tf-validate shortcuts.
infra/terraform/                All AWS. backend.tf (S3 state), versions.tf (providers),
                                network.tf (VPC), eks.tf, rds.tf, ecr.tf,
                                iam-github-oidc.tf (GHA role), addons.tf (LB ctrl + ESO),
                                eso-irsa.tf (ESO→SecretsManager), waf.tf, alarms.tf,
                                variables.tf, staging.tfvars (live), prod.tfvars (template).
charts/secureops/               Chart.yaml, values.yaml (base) + values-staging.yaml (live)
                                + values-prod.yaml (template); templates/: backend, frontend,
                                ingress, migrate-job, secrets (ExternalSecret), autoscaling (HPA+PDB).
argocd/                         project.yaml (allowlist), apps/staging.yaml (auto-sync app
                                + ESO ignoreDifferences), clustersecretstore.yaml,
                                bootstrap.sh (one-time installer).
ops/sleep.sh ops/wake.sh        Tested power routines (Ch. 11).
docs/                           sleep-wake.md, backup-restore.md (runbooks).
```

### 2.2 How configuration flows (follow one value end to end)

Example: the backend image tag. `release.yml` computes `sha-<12>` (`meta` job)
→ build/push jobs tag ECR images with it → human pins the same string into
`values-staging.yaml: backend.image.tag` → ArgoCD renders chart → Deployment
`secureops-staging-backend` pulls `…-backend:sha-xxx`. Four files, one string,
zero ambiguity — and because ECR tags are immutable, the string always means
the scanned bytes. Trace any other value the same way: *producer → git →
consumer*, never consumer-to-producer guesses.

Cross-reference map (where to look when changing X):

| Change X | Files to touch | Verifier |
|---|---|---|
| App code (API/UI) | `backend/*` or `frontend/src/*` | `ci.yml` + local tests |
| Prod image shape | `backend/Dockerfile`, `frontend/Dockerfile`, `frontend/nginx*.conf` | `docker build` locally, then Release |
| Infra sizing | `staging.tfvars` (+ `variables.tf` for new knobs) | `terraform plan` |
| Secrets consumed | `backend` code + `secrets.yaml` + Secrets Manager | ESO `SecretSynced` status |
| Deploy behavior | `charts/.../templates/*`, `values-staging.yaml` | `helm template` + ArgoCD diff |
| Pipeline | `.github/workflows/*` | Next push to `main` |
| Access/DNS/TLS | `values-staging.yaml` ingress + registrar/ACM | `curl` + controller logs |

### 2.3 What to read first (guided path)

Day 1: this chapter + `README.md` + `docker-compose.yml` (5 min).
Day 2: `charts/secureops/values*.yaml` + one template (`backend.yaml`), then
`argocd/apps/staging.yaml`. Day 3: `release.yml` top to bottom, then
`infra/terraform/{network,eks,rds}.tf`. Everything else on demand via the map.
