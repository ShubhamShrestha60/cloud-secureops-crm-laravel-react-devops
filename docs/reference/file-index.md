# File Index

What every DevOps-relevant file does, and where it is explained.

## Repository root

| File | Purpose | Chapter |
|---|---|---|
| `README.md` | project overview, decommissioned status, doc links | 00 |
| `Makefile` | convenience targets: lint/test/build/deploy helpers | 03, 10 |
| `docker-compose.yml` | local backend + frontend + PostgreSQL | 03 |
| `.env.example` | local compose env template | 03, 21 |
| `.gitignore` | keeps secrets/state/build output out of Git | 03 |
| `.github/dependabot.yml` | dependency update PRs | 10 |
| `.github/workflows/ci.yml` | PR checks: Pint, PHPUnit, ESLint, Vitest, Hadolint, Shellcheck, Gitleaks | 10 |
| `.github/workflows/release.yml` | build → Trivy gate → push immutable images | 11 |

## Infrastructure (`infra/terraform/`)

| File | Purpose | Chapter |
|---|---|---|
| `versions.tf` | Terraform/provider version constraints | 04 |
| `backend.tf` | S3 state + DynamoDB locking | 04 |
| `variables.tf` | all input variables and defaults | 04, 06 |
| `staging.tfvars` | staging overrides (EKS 1.32, 2 AZs, `t3.small`, backups 1 day) | 06 |
| `prod.tfvars` | production-shaped template (not deployed) | 06 |
| `network.tf` | VPC, public/private subnets, IGW, NAT, routes, subnet tags | 05 |
| `eks.tf` | EKS control plane, managed node group, OIDC | 06 |
| `addons.tf` | VPC CNI, CoreDNS, kube-proxy, EBS CSI, AWS LB Controller | 06 |
| `eso-irsa.tf` | IRSA role for External Secrets Operator | 07, 13 |
| `iam-github-oidc.tf` | GitHub OIDC provider + release role (ECR only) | 08 |
| `ecr.tf` | private repos, immutable tags, scan-on-push, lifecycle | 08 |
| `rds.tf` | PostgreSQL 16, subnet group, SG, Secrets Manager secret | 07 |
| `alarms.tf` | SNS topic/subscription + RDS CPU/storage + ALB 5xx alarms | 16, 19 |
| `waf.tf` | WAFv2 ACL (managed rules + IP rate limit) associated to ALB | 14 |
| `outputs.tf` | cluster, RDS, ECR, role, secret names | 04–08 |
| `README.md` | infra-specific notes and commands | 04 |
| `.terraform.lock.hcl` | provider checksums | 04 |

## Kubernetes / GitOps

| File | Purpose | Chapter |
|---|---|---|
| `argocd/bootstrap.sh` | install ArgoCD, apply project/app | 13 |
| `argocd/project.yaml` | AppProject allowlist for repo/namespaces | 13 |
| `argocd/apps/staging.yaml` | Application: chart path, values, syncPolicy, waves | 13 |
| `argocd/clustersecretstore.yaml` | External Secrets → AWS Secrets Manager store | 07 |
| `charts/secureops/Chart.yaml` | chart metadata | 12 |
| `charts/secureops/values.yaml` | safe defaults | 12 |
| `charts/secureops/values-staging.yaml` | real ECR tags, host, TLS, secret IDs | 12, 14 |
| `charts/secureops/values-prod.yaml` | production-shaped overrides | 12 |
| `charts/secureops/templates/_helpers.tpl` | names/labels | 12 |
| `charts/secureops/templates/backend.yaml` | backend Deployment + Service, probes, securityContext | 12 |
| `charts/secureops/templates/frontend.yaml` | frontend Deployment + Service | 12 |
| `charts/secureops/templates/migrate-job.yaml` | migration Job (Helm hook + ArgoCD wave) | 12 |
| `charts/secureops/templates/secrets.yaml` | Secret / ExternalSecret templates | 07, 12 |
| `charts/secureops/templates/autoscaling.yaml` | backend/frontend HPA + backend PDB | 12 |
| `charts/secureops/templates/ingress.yaml` | ALB Ingress, `/api` and `/` routing | 12, 14 |

## Containers

| File | Purpose | Chapter |
|---|---|---|
| `backend/Dockerfile` | multi-stage PHP-FPM + nginx runtime, non-root :8080 | 09 |
| `backend/.dockerignore` | excludes vendor/node_modules/env from build context | 09 |
| `backend/docker/entrypoint.sh` | DB wait, key check, migrations gate, exec supervisor | 09 |
| `backend/docker/nginx/default.conf` | PHP-FPM upstream on :8080 | 09 |
| `backend/docker/php/php.ini`, `opcache.ini` | runtime tuning | 09 |
| `backend/docker/supervisor/supervisord.conf` | nginx + php-fpm processes | 09 |
| `frontend/Dockerfile` | Vite build → nginx runtime, non-root :8080 | 09 |
| `frontend/.dockerignore` | excludes node_modules/dist/env | 09 |
| `frontend/nginx.conf` | SPA routing, caching, security headers, `/api` fallback proxy | 09 |
| `frontend/nginx-main.conf` | nginx main config (pid/temp paths, user) | 09 |

## Operations

| File | Purpose | Chapter |
|---|---|---|
| `ops/sleep.sh` | node group → 0, stop RDS; known 10-min false fatal | 17 |
| `ops/wake.sh` | node group → 3, start RDS, wait for readiness | 17 |
| `docs/sleep-wake.md` | original power runbook | 17 |
| `docs/backup-restore.md` | original backup/restore notes | 17 |

## Application entry points (not covered line by line)

| File | Purpose | Chapter |
|---|---|---|
| `backend/routes/api.php` | API routes (`/api/v1/*`) | 15 |
| `backend/app/Http/Controllers/*` | auth, contacts, security logs | 15 |
| `backend/config/*` | Laravel config consumed by env vars | 21 |
| `backend/database/migrations/*` | schema; run by migration Job | 15 |
| `backend/database/seeders/DatabaseSeeder.php` | admin seed + optional demo contacts | 15 |
| `frontend/src/api/*` | API client; base URL `/api/v1` | 15 |
| `frontend/vite.config.js` | local dev proxy/build config | 09 |

## Documentation

| File | Purpose |
|---|---|
| `docs/DEVOPS_ENGINEERING_MANUAL.md` | master manual / entry point |
| `docs/devops-manual/01`–`13` | concept + implementation chapters |
| `docs/build-from-zero/00`–`20` | this sequential rebuild volume |
| `docs/reference/command-index.md` | every command with safety labels |
| `docs/reference/file-index.md` | this file |
| `docs/reference/errors.md` | error message → cause → fix |
| `docs/reference/environment-variables.md` | env var reference |
| `docs/build-from-zero/appendix/full-files.md` | complete DevOps file contents |
| `docs/PROJECT_JOURNAL.md` | dated timeline, incidents, private postmortem |
