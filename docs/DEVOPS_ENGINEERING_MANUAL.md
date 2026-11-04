# SecureOps DevOps Engineering Manual

> **Status: decommissioned on 2026-11-04.** The AWS environment described here
> no longer exists. Every "live", "current", or observed-state statement below
> refers to the October 2026 deployment and is preserved as an as-built record.
> Use this book to understand what was built and to rebuild it; do not expect
> any command that reads the live system to return the historical values.

**A book-length operator's guide to the SecureOps CRM hosting stack:
AWS EKS + Terraform + ECR + GitHub Actions (OIDC) + Helm + ArgoCD,
serving a Laravel 12 API and a React SPA on `staging.shubham-shrestha.com.np`.**

Audience: a junior DevOps engineer (~1 year experience) progressing toward
mid-level — someone who can run commands but wants to *own* the system:
understand every component, operate it, debug it, rebuild it, cost it, and
explain the trade-offs in an interview.

## How this book is organized (read in order)

| Part | Chapter file | What you learn |
|---|---|---|
| I — Understanding | `01-overview-tour.md` | What the project is, repo tour |
| I — Understanding | `02-architecture.md` | End-to-end architecture, flows, failure domains |
| II — Foundations | `03-foundations.md` | Linux, Git, HTTP/DNS/TLS, containers, CI/CD, cloud/IAM, IaC, K8s, observability — only what this stack needs |
| III — Infrastructure | `04-infrastructure.md` | Every Terraform component, IAM trust, networking, state |
| IV — Delivery | `05-containers-delivery.md` | Dockerfiles, ECR, Helm chart, GitOps deploy path |
| V — Pipelines | `06-cicd.md` | CI + gated Release, OIDC, Trivy, promotion/rollback |
| VI — Net & Security | `07-networking-security.md` | DNS, TLS/ACM/CAA, ALB, WAF, security groups, secrets, supply chain |
| VII — Operations | `08-observability-ops.md` | Health model, logs, alarms, incident method |
| VIII — Reference | `09-command-reference.md` | Task-grouped command handbook with safety labels |
| IX — Troubleshooting | `10-troubleshooting.md` | 12 scenario runbooks in symptoms→prevention format |
| X — Lifecycle | `11-lifecycle-cost.md` | Rebuild, backup/restore, sleep/wake, teardown, cost model |
| XI–XII — Judgment | `12-decisions-exercises.md` | Design critiques, alternatives, backlog, exercises + solutions |
| Appendix | `13-glossary-quickref.md` | Glossary, risk register, quick reference, sources |

Companion runbooks already in this repo (referenced, not duplicated):
`docs/sleep-wake.md`, `docs/backup-restore.md`.

## Build from zero (sequential rebuild volume)

This book explains the system as built. To rebuild it line by line, use the
companion volume, which starts at an empty AWS account and ends at a verified
HTTPS deployment:

| Step | File | Scope |
|---|---|---|
| 00 | `build-from-zero/00-read-me-first.md` | how to use the volume, cost/safety rules |
| 01 | `build-from-zero/01-accounts-budget-domain.md` | account, budget, domain |
| 02 | `build-from-zero/02-workstation-setup.md` | tools, clock, auth |
| 03 | `build-from-zero/03-repo-and-local-environment.md` | repo, compose, local run |
| 04 | `build-from-zero/04-aws-bootstrap-and-remote-state.md` | state bucket, lock table |
| 05 | `build-from-zero/05-network-vpc-subnets-nat.md` | VPC and networking |
| 06 | `build-from-zero/06-eks-cluster-nodes-addons.md` | EKS and node group |
| 07 | `build-from-zero/07-rds-secrets.md` | PostgreSQL and secrets |
| 08 | `build-from-zero/08-ecr-and-github-oidc.md` | ECR and OIDC |
| 09 | `build-from-zero/09-docker-images.md` | image internals |
| 10 | `build-from-zero/10-ci-pipeline.md` | pull-request checks |
| 11 | `build-from-zero/11-release-pipeline.md` | scan-before-push release |
| 12 | `build-from-zero/12-helm-chart.md` | chart and workloads |
| 13 | `build-from-zero/13-argocd-gitops.md` | ArgoCD and sync |
| 14 | `build-from-zero/14-alb-ingress-tls-waf.md` | ALB, ACM, DNS, WAF |
| 15 | `build-from-zero/15-first-deploy-and-verification.md` | end-to-end proof |
| 16 | `build-from-zero/16-operate-debug-and-observe.md` | day-2 operations |
| 17 | `build-from-zero/17-sleep-wake-backup-restore.md` | power and restore drills |
| 18 | `build-from-zero/18-teardown-zero-cost.md` | deletion order and orphan sweep |
| 19 | `build-from-zero/19-cost-guardrails.md` | budgets and cost controls |
| 20 | `build-from-zero/20-rebuild-checklist.md` | one-page rebuild gate |

Reference and source material:

- `reference/command-index.md` — every command with a safety label.
- `reference/file-index.md` — what each DevOps file does.
- `reference/errors.md` — exact error → cause → fix.
- `reference/environment-variables.md` — Terraform, GitHub, Helm, and process env.
- `build-from-zero/appendix/full-files.md` — sanitized complete file contents.
- `PROJECT_JOURNAL.md` — dated timeline, incidents, and private postmortem.

## Reading conventions used throughout

- **File references** look like `infra/terraform/eks.tf:14` (path + line).
- **Facts vs. inference.** `FACT` = verified in repo files or observed live during
  setup. `INFERENCE` = reasonable conclusion, stated as such. `VERIFY` = needs
  a live check; the exact safe command is given. `RECOMMENDATION` = opinion.
- **Command safety labels.** Every operational command is tagged:
  `READ-ONLY`, `STATE-CHANGING` (creates/mutates infra or workloads),
  or `DESTRUCTIVE` (deletes data or billing resources — irreversible).
- **Placeholders.** `<account-id>`, `<repo-url>`, `ghp_…`, `sha-xxxxxxxxxxxx`.
  Real account IDs already present in repo files (ECR URLs, backend config)
  are reproduced where the implementation requires them; no secret *values*,
  tokens, passwords, keys, or state contents appear anywhere.
- **Region.** Everything lives in `ap-south-1` (Mumbai) unless stated.
  ACM certificates *must* live in the same region as the ALB — this constraint
  drives several procedures in Chapters 7 and 10.
- **Mermaid diagrams** render on GitHub and in most Markdown editors.

## What this stack is (30-second version)

Push to `main` → `ci.yml` runs fast checks → `release.yml` builds both images
locally, Trivy-scans them, and pushes **only clean builds** to ECR under
immutable `sha-xxx` tags (GitHub authenticates to AWS via OIDC — no static
keys). ArgoCD, running in the EKS cluster, notices the new tag pinned in
`charts/secureops/values-staging.yaml`, runs a migrate Job first, then rolls
new backend/frontend pods. An ALB Ingress routes `/api/*` to Laravel and `/`
to the SPA over ACM-terminated HTTPS with a WAF in front. Postgres runs on
RDS; passwords live in Secrets Manager and reach pods via External Secrets.
CloudWatch alarms watch RDS and ALB 5xx. Terraform owns all of it with remote
S3 state. Total steady burn ≈ $199/mo awake, ≈ $100/mo asleep (see Ch. 11).
