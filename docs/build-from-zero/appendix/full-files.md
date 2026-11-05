# Appendix — Complete DevOps Files

Sanitized verbatim contents of the DevOps-relevant files. Application source is intentionally excluded. Placeholders: `<ACCOUNT_ID>`, `<GITHUB_OWNER>/<GITHUB_REPO>`, `<ACM_CERT_ARN>`, `<DB_PASSWORD>`, `<CHANGE_ME>`, `<APP_KEY>`.

> `docker-compose.yml` is reproduced from `HEAD`, not the working tree. The public portfolio uses the same committed version.

## Contents

- `README.md`
- `Makefile`
- `docker-compose.yml`
- `.env.example`
- `.gitignore`
- `.github/dependabot.yml`
- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `infra/terraform/README.md`
- `infra/terraform/versions.tf`
- `infra/terraform/backend.tf`
- `infra/terraform/variables.tf`
- `infra/terraform/staging.tfvars`
- `infra/terraform/prod.tfvars`
- `infra/terraform/network.tf`
- `infra/terraform/eks.tf`
- `infra/terraform/addons.tf`
- `infra/terraform/eso-irsa.tf`
- `infra/terraform/iam-github-oidc.tf`
- `infra/terraform/ecr.tf`
- `infra/terraform/rds.tf`
- `infra/terraform/alarms.tf`
- `infra/terraform/waf.tf`
- `infra/terraform/outputs.tf`
- `argocd/bootstrap.sh`
- `argocd/project.yaml`
- `argocd/apps/staging.yaml`
- `argocd/clustersecretstore.yaml`
- `charts/secureops/Chart.yaml`
- `charts/secureops/values.yaml`
- `charts/secureops/values-staging.yaml`
- `charts/secureops/values-prod.yaml`
- `charts/secureops/templates/_helpers.tpl`
- `charts/secureops/templates/backend.yaml`
- `charts/secureops/templates/frontend.yaml`
- `charts/secureops/templates/migrate-job.yaml`
- `charts/secureops/templates/secrets.yaml`
- `charts/secureops/templates/autoscaling.yaml`
- `charts/secureops/templates/ingress.yaml`
- `backend/Dockerfile`
- `backend/.dockerignore`
- `backend/docker/entrypoint.sh`
- `backend/docker/nginx/default.conf`
- `backend/docker/php/php.ini`
- `backend/docker/php/opcache.ini`
- `backend/docker/supervisor/supervisord.conf`
- `frontend/Dockerfile`
- `frontend/.dockerignore`
- `frontend/nginx.conf`
- `frontend/nginx-main.conf`
- `ops/sleep.sh`
- `ops/wake.sh`
- `docs/sleep-wake.md`
- `docs/backup-restore.md`

---

## `README.md`

```markdown
# SecureOps CRM — EKS production hosting

> **Status: decommissioned on 2026-11-04.** All AWS resources for this project
> have been deleted. The live URL, EKS cluster, RDS database, ALB, WAF, and
> node groups no longer exist. This repository is retained as an as-built
> record and reproducible rebuild guide, not as a running service.

Laravel 12 API + React SPA, hosted on AWS EKS with Terraform + Helm + ArgoCD.
ECR holds versioned images. No static AWS keys: GHA uses OIDC.

Historical deployment: `https://staging.shubham-shrestha.com.np` (single
prod-like env named `staging`; `*-prod.*` files are retained as templates for a
second env). The hostname is kept in this record as an archived example and no
longer serves the application.

## Documentation

- **Start here:** [`docs/DEVOPS_ENGINEERING_MANUAL.md`](docs/DEVOPS_ENGINEERING_MANUAL.md) — the complete operator's manual and index.
- **Rebuild from zero:** [`docs/build-from-zero/00-read-me-first.md`](docs/build-from-zero/00-read-me-first.md) — chronological, command-level setup.
- **Project journal:** [`docs/PROJECT_JOURNAL.md`](docs/PROJECT_JOURNAL.md) — dated build, incident, and teardown history.
- **Portfolio source:** [`portfolio/README.md`](portfolio/README.md) — the sanitized DevOps-only showcase published to the public repo.

## Architecture

```
GitHub (main) -> release.yml -> ECR (sha + semver, Trivy-gated)
Git (charts/secureops + values-*.yaml) -> ArgoCD -> EKS
ALB (Ingress) -> /api/* backend Service :80->:8080, /* frontend Service
Backend -> RDS Postgres 16 (Secrets Manager via External Secrets)
```

## Layout

- `backend/Dockerfile` + `backend/docker/` — php-fpm + nginx + supervisor on 8080 as `www-data`
- `frontend/Dockerfile` + `frontend/nginx.conf` — Vite build served by nginx on 8080
- `docker-compose.yml` — dev-only local loop, never prod
- `.github/workflows/ci.yml` — PR checks (Pint, PHPUnit, ESLint, Vitest, Hadolint, Gitleaks)
- `.github/workflows/release.yml` — build/scan/push to ECR (needs `AWS_REGION`, `AWS_ROLE_TO_ASSUME`, `ECR_*` vars)
- `infra/terraform/` — VPC, EKS, RDS, ECR, GHA OIDC, ALB controller, External Secrets
- `charts/secureops/` — Helm chart with migrate Job, HPA, PDB, Ingress, ExternalSecret
- `argocd/` — Project + staging (auto-sync) + prod (manual-sync) Applications

## Start to finish hosting

1. `cp .env.example .env` and set `DB_PASSWORD` for local dev only.
2. Local check: `docker compose config` (needs Docker; CI also runs it).
3. `terraform -chdir=infra/terraform init` then `plan/apply -var-file=staging.tfvars`.
4. Copy outputs: ECR URLs into Helm values, role ARN into GHA `AWS_ROLE_TO_ASSUME`.
5. Push to `main` — `release.yml` builds `sha-<12>` and pushes to ECR.
6. Update `charts/secureops/values-staging.yaml` image tags, merge.
7. `argocd/bootstrap.sh` once per cluster, then ArgoCD syncs staging automatically.
8. Promote: update `values-prod.yaml` tags, merge, manual Sync `secureops-prod` in ArgoCD.
9. Verify: `https://<alb-host>/api/v1/health` and `/` serve SecureOps.

## Prod checklist

- `APP_KEY`, DB creds only in Secrets Manager, never in git or image layers.
- `SKIP_MIGRATIONS=true` in Deployment; Helm pre-upgrade Job owns `migrate --force`.
- Probes: liveness `/up` (`backend/bootstrap/app.php:12`), readiness `/api/v1/health`.
- ECR immutable tags + lifecycle keep-20 + scan-on-push + Trivy gate in CI.
- RDS: encrypted, PITR backups, `multi_az=true` in prod, deletion protection.
```

## `Makefile`

```makefile
.PHONY: up down build logs ps seed helm-lint tf-validate

up:
	docker compose up --build -d

down:
	docker compose down

build:
	docker compose build

logs:
	docker compose logs -f

ps:
	docker compose ps

seed:
	docker compose exec backend php artisan db:seed --force

helm-lint:
	helm lint charts/secureops -f charts/secureops/values-staging.yaml
	helm lint charts/secureops -f charts/secureops/values-prod.yaml
	helm template secureops charts/secureops -f charts/secureops/values-staging.yaml --namespace secureops-staging | kubeconform -strict -summary || true

tf-validate:
	terraform -chdir=infra/terraform init -backend=false
	terraform -chdir=infra/terraform validate
	terraform -chdir=infra/terraform fmt -check -recursive
```

## `docker-compose.yml`

```yaml
# Dev-only Compose. Production traffic runs on EKS (Terraform + Helm + ArgoCD).
# This file exists for: fast local loop, onboarding, and CI integration tests
# without paying for EKS per push. Do NOT use it as a prod deploy story.
services:
  database:
    image: postgres:16-alpine
    container_name: secureops-db
    restart: unless-stopped
    env_file:
      - .env
    environment:
      POSTGRES_DB: ${DB_DATABASE:-secureops}
      POSTGRES_USER: ${DB_USERNAME:-secureops}
      POSTGRES_PASSWORD: ${DB_PASSWORD:?Set DB_PASSWORD in .env}
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - secureops
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USERNAME:-secureops} -d ${DB_DATABASE:-secureops}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: secureops-backend
    restart: unless-stopped
    env_file:
      - .env
    environment:
      APP_ENV: ${APP_ENV:-local}
      APP_DEBUG: ${APP_DEBUG:-false}
      APP_URL: ${APP_URL:-http://localhost:8000}
      FRONTEND_URL: ${FRONTEND_URL:-http://localhost:5173}
      CORS_ALLOWED_ORIGINS: ${CORS_ALLOWED_ORIGINS:-http://localhost:5173}
      LOG_CHANNEL: stderr
      LOG_LEVEL: debug
      DB_CONNECTION: pgsql
      DB_HOST: database
      DB_PORT: 5432
      DB_DATABASE: ${DB_DATABASE:-secureops}
      DB_USERNAME: ${DB_USERNAME:-secureops}
      DB_PASSWORD: ${DB_PASSWORD:?Set DB_PASSWORD in .env}
      SKIP_MIGRATIONS: "false"
    ports:
      - "${BACKEND_PORT:-8000}:8080"
    depends_on:
      database:
        condition: service_healthy
    networks:
      - secureops
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/up | grep -qE 'OK|\"status\"' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    container_name: secureops-frontend
    restart: unless-stopped
    ports:
      - "${FRONTEND_PORT:-5173}:8080"
    depends_on:
      backend:
        condition: service_healthy
    networks:
      - secureops
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/ | grep -q SecureOps || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s

networks:
  secureops:
    name: secureops
    driver: bridge

volumes:
  pgdata:
    name: secureops-pgdata
```

## `.env.example`

```bash
# Production environment — copy to `.env` and fill secrets.
# Never commit `.env` with real passwords.
APP_ENV=local
APP_DEBUG=false
APP_KEY=
APP_URL=http://localhost:8000
FRONTEND_URL=http://localhost:5173
CORS_ALLOWED_ORIGINS=http://localhost:5173

DB_DATABASE=secureops
DB_USERNAME=secureops
DB_PASSWORD=<DB_PASSWORD>

BACKEND_PORT=8000
FRONTEND_PORT=5173

SEED_ADMIN_EMAIL=admin@secureops.local
SEED_ADMIN_PASSWORD=<CHANGE_ME>
SEED_DEMO_CONTACTS=false
```

## `.gitignore`

```gitignore
# Composer
/composer.phar

# Environment files
.env
.env.*
!**/.env.example

# Dependencies
/vendor/
node_modules/
backend/vendor/
backend/node_modules/
frontend/node_modules/

# Build output
/dist/
frontend/dist/

# PHPUnit
.phpunit.cache/

# Storage / secrets
storage/*.key

# macOS
.DS_Store

# Terraform
*.tfstate
*.tfstate.*
.terraform/
*.auto.tfvars
crash.log
override.tf
override.tf.json




# keep lockfile, drop cache
!**/.terraform.lock.hcl
terraform.tfstate.backup


# Keep regular staging/prod .tfvars files
# (they currently contain no secrets)

# Project dump
project_dump.txt

# AWS / Kubernetes / certificates / keys
.aws/
kubeconfig
*.pem
*.key




**/storage/*.key
**/.phpunit.cache/
**/public/build
**/public/hot
```

## `.github/dependabot.yml`

```yaml
version: 2
updates:
  # Pinned CI actions rotted twice during this project's setup
  # (trivy-action tags, setup-trivy chain) — automate the bumps.
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
    commit-message: { prefix: "chore" }

  - package-ecosystem: docker
    directory: /backend
    schedule: { interval: weekly }
    commit-message: { prefix: "chore" }

  - package-ecosystem: docker
    directory: /frontend
    schedule: { interval: weekly }
    commit-message: { prefix: "chore" }

  - package-ecosystem: terraform
    directory: /infra/terraform
    schedule: { interval: weekly }
    commit-message: { prefix: "chore" }
```

## `.github/workflows/ci.yml`

```yaml
name: CI

# Fast PR checks only. Image build/push/deploy lives in release.yml + ArgoCD.
# Keeps feedback <5 min and never needs AWS credentials.

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  backend:
    name: Backend (Pint + PHPUnit)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up PHP
        uses: shivammathur/setup-php@v2
        with:
          php-version: "8.3"
          extensions: mbstring, pdo_sqlite, sqlite3
          coverage: none
          tools: composer

      - name: Install dependencies
        working-directory: backend
        run: composer install --no-interaction --prefer-dist

      - name: Pint (code style)
        working-directory: backend
        run: ./vendor/bin/pint --test

      - name: PHPUnit
        working-directory: backend
        run: php artisan test --colors=never

  frontend:
    name: Frontend (ESLint + Vitest + Build)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
          cache-dependency-path: frontend/package-lock.json

      - name: Install dependencies
        working-directory: frontend
        run: npm ci --no-audit --no-fund

      - name: ESLint
        working-directory: frontend
        run: npm run lint

      - name: Vitest
        working-directory: frontend
        run: npm run test -- --run

      - name: Build
        working-directory: frontend
        run: npm run build

  containers:
    name: Containers (Hadolint + Shellcheck + Compose)
    runs-on: ubuntu-latest
    needs: [backend, frontend]
    steps:
      - uses: actions/checkout@v4

      - name: Hadolint backend
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: backend/Dockerfile

      - name: Hadolint frontend
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: frontend/Dockerfile

      - name: Shellcheck entrypoint
        run: shellcheck backend/docker/entrypoint.sh

      - name: Validate dev compose config
        run: docker compose config --quiet

  secrets:
    name: Gitleaks
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## `.github/workflows/release.yml`

```yaml
name: Release (build, scan, push to ECR)

# Gated pipeline: each image is built LOCALLY, scanned, and pushed to ECR
# only if its own scan passes. Nothing vulnerable ever leaves the runner.
# ArgoCD pulls from ECR — this workflow never touches the cluster (GitOps pull model).
# Required repo Variables: AWS_REGION, AWS_ROLE_TO_ASSUME,
#   ECR_BACKEND_REPOSITORY, ECR_FRONTEND_REPOSITORY
# Required: OIDC trust from the ECR/IAM Terraform module to this repo.
#
# NOTE: provenance/SBOM attestations are intentionally OFF here. Attestations
# require build-push-action to push directly, which would put push before scan.
# The exact scanned image object is pushed via `docker push`, so bytes scanned
# == bytes stored. (ECR scan-on-push remains as a backstop.)

on:
  push:
    branches: [main]
    tags: ["v*.*.*"]
  workflow_dispatch:
    inputs:
      tag:
        description: "Override image tag (default: git sha)"
        required: false
        default: ""

permissions:
  contents: read
  id-token: write
  security-events: write

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

env:
  AWS_REGION: ${{ vars.AWS_REGION }}
  ECR_BACKEND_REPOSITORY: ${{ vars.ECR_BACKEND_REPOSITORY }}
  ECR_FRONTEND_REPOSITORY: ${{ vars.ECR_FRONTEND_REPOSITORY }}

jobs:
  meta:
    name: Resolve tag
    runs-on: ubuntu-latest
    outputs:
      value: ${{ steps.tag.outputs.value }}
    steps:
      - name: Resolve tag
        id: tag
        run: |
          if [ -n "${{ inputs.tag }}" ]; then
            echo "value=${{ inputs.tag }}" >> "$GITHUB_OUTPUT"
          elif [[ "$GITHUB_REF" == refs/tags/v* ]]; then
            echo "value=${GITHUB_REF#refs/tags/}" >> "$GITHUB_OUTPUT"
          else
            echo "value=sha-${GITHUB_SHA::12}" >> "$GITHUB_OUTPUT"
          fi

  backend:
    name: Backend (build, scan, push)
    runs-on: ubuntu-latest
    needs: [meta]
    env:
      TAG: ${{ needs.meta.outputs.value }}
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ vars.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      # Local-only build, tagged with its final ECR name but NOT pushed.
      - name: Build backend (local)
        uses: docker/build-push-action@v6
        with:
          context: ./backend
          push: false
          load: true
          platforms: linux/amd64
          tags: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_BACKEND_REPOSITORY }}:${{ env.TAG }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      # Gate: fails the job on HIGH/CRITICAL. Push below is skipped.
      - name: Trivy scan backend
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_BACKEND_REPOSITORY }}:${{ env.TAG }}
          format: table
          severity: HIGH,CRITICAL
          exit-code: "1"

      # SARIF copy for the Security tab (never gates; DB already cached).
      - name: Trivy SARIF backend
        if: always()
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_BACKEND_REPOSITORY }}:${{ env.TAG }}
          format: sarif
          output: trivy-backend.sarif
          severity: HIGH,CRITICAL
          exit-code: "0"

      - name: Upload SARIF backend
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy-backend.sarif
          category: trivy-backend

      # Pushes the exact image object that was just scanned.
      - name: Push backend to ECR
        run: docker push ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_BACKEND_REPOSITORY }}:${{ env.TAG }}

  frontend:
    name: Frontend (build, scan, push)
    runs-on: ubuntu-latest
    needs: [meta]
    env:
      TAG: ${{ needs.meta.outputs.value }}
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_TO_ASSUME }}
          aws-region: ${{ vars.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build frontend (local)
        uses: docker/build-push-action@v6
        with:
          context: ./frontend
          push: false
          load: true
          platforms: linux/amd64
          tags: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_FRONTEND_REPOSITORY }}:${{ env.TAG }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Trivy scan frontend
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_FRONTEND_REPOSITORY }}:${{ env.TAG }}
          format: table
          severity: HIGH,CRITICAL
          exit-code: "1"

      - name: Trivy SARIF frontend
        if: always()
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_FRONTEND_REPOSITORY }}:${{ env.TAG }}
          format: sarif
          output: trivy-frontend.sarif
          severity: HIGH,CRITICAL
          exit-code: "0"

      - name: Upload SARIF frontend
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy-frontend.sarif
          category: trivy-frontend

      - name: Push frontend to ECR
        run: docker push ${{ steps.login-ecr.outputs.registry }}/${{ env.ECR_FRONTEND_REPOSITORY }}:${{ env.TAG }}

  summary:
    name: Summary
    runs-on: ubuntu-latest
    needs: [meta, backend, frontend]
    steps:
      - run: |
          echo "Pushed tag: ${{ needs.meta.outputs.value }}"
          echo "Both images scanned clean (HIGH/CRITICAL gate) before push."
          echo "Next: pin charts/secureops/values-staging.yaml image.tags to ${{ needs.meta.outputs.value }}."

  notify-failure:
    name: Scan-gate failure notice
    runs-on: ubuntu-latest
    needs: [meta, backend, frontend]
    if: failure()
    steps:
      - run: |
          echo "::error::Release gate blocked tag ${{ needs.meta.outputs.value }}: Trivy found HIGH/CRITICAL vulnerabilities."
          echo "Nothing was pushed to ECR for the failing image (verify with: aws ecr describe-images)."
          echo "Read the CVE table in the failed scan step above, fix base/app layers, then push a new commit."
```

## `infra/terraform/README.md`

```markdown
# Terraform — SecureOps EKS stack

## Prereqs

- AWS account + `aws login` (SSO preferred, no static keys in repo)
- S3 bucket + DynamoDB table for state (see `backend.tf` comments)
- `terraform >= 1.6`, `aws cli >= 2`, `helm >= 3.14`, `kubectl`

## First apply (staging)

```bash
terraform init
terraform plan -var-file=staging.tfvars -var github_repo=OWNER/REPO
terraform apply -var-file=staging.tfvars -var github_repo=OWNER/REPO
```

Copy outputs:

- `ecr_backend_url` / `ecr_frontend_url` -> Helm `values-*.yaml` image.repository
- `github_release_role_arn` -> GHA repo Variable `AWS_ROLE_TO_ASSUME`
- `rds_endpoint` for debugging (app reads it from Secrets Manager, not tfvars)

Then:

```bash
aws eks update-kubeconfig --name secureops-staging --region ap-south-1
kubectl get nodes
bash ../../argocd/bootstrap.sh
```

## Prod

```bash
terraform workspace new prod  # or separate state key per backend.hcl
terraform apply -var-file=prod.tfvars -var github_repo=OWNER/REPO
```

Prod differences (`prod.tfvars`): 3 AZs, `db.t3.small`, `multi_az=true`,
7-day backups, deletion protection, External Secrets enforced
(`secrets.create=false` in `values-prod.yaml`).

## Cost control

Staging uses 2 AZs, single NAT, `db.t3.micro`, 1-day backups.
Tear down dev clusters with `terraform destroy -var-file=staging.tfvars` when idle.
```

## `infra/terraform/versions.tf`

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}

# Helm talks to EKS after the cluster exists. Auth via exec (aws cli).
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
```

## `infra/terraform/backend.tf`

```hcl
# Remote state: create the bucket + lock table once (outside this stack),
# then uncomment and fill in. Do NOT commit real bucket names with secrets —
# bucket name itself is fine, it holds state not app secrets.
#
terraform {
  backend "s3" {
    bucket         = "secureops-tfstate-<ACCOUNT_ID>"
    key            = "secureops/eks/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "secureops-terraform-locks"
    encrypt        = true
  }
}
# Bootstrap (one time, with admin creds):
#   aws s3 mb s3://secureops-terraform-state-<account-id> --region ap-south-1
#   aws dynamodb create-table --table-name secureops-terraform-locks \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST --region ap-south-1
```

## `infra/terraform/variables.tf`

```hcl
variable "project" {
  description = "Resource name prefix."
  type        = string
  default     = "secureops"
}

variable "env" {
  description = "staging | prod. Used in names + tags."
  type        = string
  validation {
    condition     = contains(["staging", "prod"], var.env)
    error_message = "env must be staging or prod."
  }
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs (2 = cheap, 3 = prod HA)."
  type        = number
  default     = 3
}

variable "eks_version" {
  description = "EKS control-plane version."
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "Managed node group instance types."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro for staging, db.t3.small+ for prod."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  type    = string
  default = "secureops"
}

variable "db_username" {
  type    = string
  default = "secureops"
}

variable "domain_name" {
  description = "Public domain for the app (Route53 + ACM). Empty = skip DNS/ACM, use ALB hostname."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repo allowed to push to ECR via OIDC, e.g. myorg/secureopsCRM_laravel-react_devops."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email for CloudWatch alarm notifications. Empty = topic only, no subscription."
  type        = string
  default     = ""
}
```

## `infra/terraform/staging.tfvars`

```hcl
project  = "secureops"
env      = "staging"
region   = "ap-south-1"
az_count = 2

eks_version         = "1.32"
node_instance_types = ["t3.small"]
node_min_size       = 2
node_max_size       = 4
# NOTE: upstream EKS module ignores desired_size after creation
# (lifecycle ignore_changes for autoscaler compat). Change node count via:
# aws eks update-nodegroup-config --cluster-name secureops-staging \
#   --nodegroup-name <name> --scaling-config minSize=2,maxSize=4,desiredSize=N
node_desired_size   = 3

db_instance_class = "db.t3.micro"
domain_name       = ""
github_repo = "<GITHUB_OWNER>/<GITHUB_REPO>"
```

## `infra/terraform/prod.tfvars`

```hcl
project  = "secureops"
env      = "prod"
region   = "ap-south-1"
az_count = 3

eks_version         = "1.32"
node_instance_types = ["t3.medium"]
node_min_size       = 2
node_max_size       = 4
node_desired_size   = 2

db_instance_class = "db.t3.small"
domain_name       = ""
# github_repo = "OWNER/secureopsCRM_laravel-react_devops"
```

## `infra/terraform/network.tf`

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${var.project}-${var.env}"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 100)]

  enable_nat_gateway   = true
  single_nat_gateway   = var.env == "staging" # one NAT to save cost; prod uses one per AZ
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required tags so the AWS LB Controller auto-discovers subnets.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
```

## `infra/terraform/eks.tf`

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = "${var.project}-${var.env}"
  cluster_version = var.eks_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # K8s API auth: creator gets admin. Add team IAM ARNs here for real prod.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # EBS volumes for pods (scratch, not DB — DB is RDS).
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }
    }
  }

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${var.project}-${var.env}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
```

## `infra/terraform/addons.tf`

```hcl
# AWS Load Balancer Controller (installs ALB ingress class for EKS).
# The Helm chart's Ingress (alb=true) depends on this controller.

module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.project}-${var.env}-lb-controller"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.2"
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.lb_controller_irsa.iam_role_arn
  }

  depends_on = [module.eks]
}

# External Secrets Operator: syncs Secrets Manager -> K8s Secrets so the
# backend Deployment never needs long-lived DB passwords in git.
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.4"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eso_irsa.iam_role_arn
  }

  depends_on = [module.eks, helm_release.lb_controller]
}
```

## `infra/terraform/eso-irsa.tf`

```hcl
# External Secrets Operator IRSA: allow ESO pods to read Secrets Manager.
# ClusterSecretStore argocd/clustersecretstore.yaml uses
# jwt.serviceAccountRef {name: external-secrets, namespace: external-secrets},
# so that SA must be annotated with this role ARN (wired in addons.tf).

module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${var.project}-${var.env}-eso"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_role_policy" "eso_secretsmanager" {
  name = "secretsmanager-read"
  role = module.eso_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/staging/*",
          "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/prod/*"
        ]
      }
    ]
  })
}

data "aws_caller_identity" "current" {}
```

## `infra/terraform/iam-github-oidc.tf`

```hcl
# GitHub Actions OIDC -> ECR push without static AWS keys.
# Set var.github_repo = "OWNER/REPO". Leave empty to skip (e.g. first plan).
# After apply: copy role ARN into GHA repo Variable AWS_ROLE_TO_ASSUME.

data "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo != "" ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo != "" ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub OIDC thumbprints (2026): GitHub serves certs via Let's Encrypt
  # hierarchy (leaf <- YR2 intermediate <- Root YR, cross-signed by ISRG Root X1).
  # Keep the legacy thumbprint as well; AWS matches any entry in the list.
  thumbprint_list = [
    "ab9d0263244dd0326eb67015705a667e79cfe998", # Root YR cross-sign
    "cabd2a79a1076a31f21d253635cb039d4329a5e8", # ISRG Root X1
    "6938fd4d98bab03faadb97b34396831e3780aea1", # legacy GitHub/DigiCert
  ]
}

locals {
  github_oidc_arn = var.github_repo != "" ? try(data.aws_iam_openid_connect_provider.github[0].arn, aws_iam_openid_connect_provider.github[0].arn) : aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_role" "github_release" {
  count = var.github_repo != "" ? 1 : 0
  name  = "${var.project}-${var.env}-github-release"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # NOTE: GitHub's sub format embeds numeric IDs:
        # repo:OWNER@ownerID/REPO@repoID:ref:... — the wildcards cover both
        # the legacy (no IDs) and current formats.
        StringLike = { "token.actions.githubusercontent.com:sub" = "repo:${split("/", var.github_repo)[0]}@*/${split("/", var.github_repo)[1]}@*:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_release_ecr" {
  count = var.github_repo != "" ? 1 : 0
  name  = "ecr-push"
  role  = aws_iam_role.github_release[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = [
          aws_ecr_repository.backend.arn,
          aws_ecr_repository.frontend.arn
        ]
      }
    ]
  })
}
```

## `infra/terraform/ecr.tf`

```hcl
resource "aws_ecr_repository" "backend" {
  name                 = "${var.project}-${var.env}-backend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.env == "staging"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project}-${var.env}-frontend"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.env == "staging"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}
```

## `infra/terraform/rds.tf`

```hcl
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.env}-rds"
  description = "Postgres access from EKS nodes only."
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-${var.env}"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_instance" "main" {
  identifier             = "${var.project}-${var.env}"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  max_allocated_storage  = 100
  storage_type           = "gp3"
  storage_encrypted      = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.env == "prod"

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  backup_retention_period = var.env == "prod" ? 7 : 1
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:00-sun:04:00"
  deletion_protection     = var.env == "prod"
  skip_final_snapshot     = var.env != "prod"

  performance_insights_enabled = var.env == "prod"

  tags = {
    Name = "${var.project}-${var.env}-postgres"
  }
}

# Store DB URL parts in Secrets Manager. The Helm chart reads them via
# External Secrets Operator or plain env-from-secret wired by ArgoCD values.
resource "aws_secretsmanager_secret" "db" {
  name = "${var.project}/${var.env}/database"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    DB_HOST     = aws_db_instance.main.address
    DB_PORT     = "5432"
    DB_DATABASE = var.db_name
    DB_USERNAME = var.db_username
    DB_PASSWORD = random_password.db.result
  })
}
```

## `infra/terraform/alarms.tf`

```hcl
# CloudWatch alarms for the live env. Notifications go to an SNS topic;
# set var.alert_email to subscribe (confirm the subscription email).
# Empty alert_email = alarms record to CloudWatch only.

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-${var.env}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project}-${var.env}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.project}-${var.env}-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Minimum"
  threshold           = 5 * 1024 * 1024 * 1024 # 5 GiB in bytes
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-${var.env}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 20
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    # CloudWatch wants the ALB "arn_suffix": app/<name>/<id>
    LoadBalancer = local.alb_suffix
  }
}
```

## `infra/terraform/waf.tf`

```hcl
# WAFv2 in front of the ALB created by the AWS LB Controller.
# The ALB itself is controller-managed, so we look it up by cluster tag
# and associate. Default action ALLOW + managed deny rules (prod posture:
# block known-bad input, rate-limit brute force like /api/v1/login).

data "aws_lbs" "app" {
  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name
  }
}

locals {
  alb_arn    = one(data.aws_lbs.app.arns)
  alb_suffix = join("/", slice(split("/", one(data.aws_lbs.app.arns)), 1, 4))
}

resource "aws_wafv2_web_acl" "app" {
  name  = "${var.project}-${var.env}-app"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "common"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "known-bad-inputs"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-badinputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "login-rate-limit"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 3000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project}-${var.env}-ratelimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project}-${var.env}-app"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.project}-${var.env}-waf"
  }
}

resource "aws_wafv2_web_acl_association" "app" {
  resource_arn = local.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.app.arn
}
```

## `infra/terraform/outputs.tf`

```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_oidc_issuer" {
  value = module.eks.cluster_oidc_issuer_url
}

output "ecr_backend_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "ecr_frontend_url" {
  value = aws_ecr_repository.frontend.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}

output "github_release_role_arn" {
  value       = try(aws_iam_role.github_release[0].arn, null)
  description = "Copy into GHA repo Variable AWS_ROLE_TO_ASSUME. Null when var.github_repo is empty."
}
```

## `argocd/bootstrap.sh`

```bash
#!/bin/sh
set -eu
# Bootstrap ArgoCD + SecureOps apps on the EKS cluster from Terraform outputs.
# Run after: terraform apply -var-file=staging.tfvars && aws eks update-kubeconfig ...

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/apps/staging.yaml

echo "ArgoCD server: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Staging (sole live env) syncs automatically on push to main."
```

## `argocd/project.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: secureops
  namespace: argocd
spec:
  description: SecureOps CRM environments
  sourceRepos:
    - https://github.com/<GITHUB_OWNER>/<GITHUB_REPO>.git
  destinations:
    - { namespace: secureops-staging, server: https://kubernetes.default.svc }
    - { namespace: secureops-prod, server: https://kubernetes.default.svc }
  clusterResourceWhitelist:
    - { group: "*", kind: "*" }
  namespaceResourceWhitelist:
    - { group: "*", kind: "*" }
```

## `argocd/apps/staging.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: secureops-staging
  namespace: argocd
  # SyncWave ordering inside the chart (migrate Job wave -5) runs before Deployments.
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: secureops
  source:
    # TODO: replace with your fork URL if different.
    repoURL: https://github.com/<GITHUB_OWNER>/<GITHUB_REPO>.git
    targetRevision: main
    path: charts/secureops
    helm:
      valueFiles:
        - values.yaml
        - values-staging.yaml
      # release.yml updates these via commit, or enable Image Updater:
      # parameters:
      #   - name: backend.image.tag
      #     value: sha-xxxxxxxxxxxx
      #   - name: frontend.image.tag
      #     value: sha-xxxxxxxxxxxx
  destination:
    server: https://kubernetes.default.svc
    namespace: secureops-staging
  # ESO defaults fields the chart doesn't set (conversion/decoding strategies,
  # deletionPolicy). Ignore them so the dashboard reflects real drift only.
  # Secret IDs (dataFrom[].key) still render from git; ID changes re-sync.
  ignoreDifferences:
    - group: external-secrets.io
      kind: ExternalSecret
      jsonPointers:
        - /spec/dataFrom
        - /spec/target/deletionPolicy
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry: { limit: 5, backoff: { duration: 5s, factor: 2, maxDuration: 3m } }
```

## `argocd/clustersecretstore.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      # Region must match Terraform var.region.
      region: ap-south-1
      auth:
        # Uses EKS IRSA: bind this ServiceAccount to the Terraform-created role
        # that can read secureops/<env>/* secrets.
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

## `charts/secureops/Chart.yaml`

```yaml
apiVersion: v2
name: secureops
description: SecureOps CRM — Laravel API + React SPA on EKS
type: application
version: 0.1.0
appVersion: "1.0.0"
```

## `charts/secureops/values.yaml`

```yaml
# Default values. Override per env with values-staging.yaml / values-prod.yaml.
# Image tags are updated by release.yml (commit) or ArgoCD Image Updater.

global:
  env: staging

backend:
  replicaCount: 2
  image:
    repository: "" # e.g. 123456789012.dkr.ecr.ap-south-1.amazonaws.com/secureops-staging-backend
    tag: "latest"
    pullPolicy: IfNotPresent
  containerPort: 8080
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { cpu: 500m, memory: 512Mi }
  env:
    APP_ENV: production
    APP_DEBUG: "false"
    LOG_CHANNEL: stderr
    LOG_LEVEL: warning
    DB_CONNECTION: pgsql
    SKIP_MIGRATIONS: "true" # Helm Job owns migrations, not the Deployment entrypoint
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
    targetCPUUtilizationPercentage: 70
  podDisruptionBudget:
    enabled: true
    minAvailable: 1

frontend:
  replicaCount: 2
  image:
    repository: ""
    tag: "latest"
    pullPolicy: IfNotPresent
  containerPort: 8080
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { cpu: 250m, memory: 256Mi }
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 4
    targetCPUUtilizationPercentage: 70

# Secrets: prod uses External Secrets (Secrets Manager -> K8s Secret).
# For kind/local demo set secrets.create=true with dummy values.
secrets:
  create: false
  # APP_KEY must be base64:xxx Laravel key in real deploys. Dummy only for lint/demo.
  data:
    APP_KEY: "<APP_KEY>"
    APP_URL: "http://localhost"
    FRONTEND_URL: "http://localhost"
    CORS_ALLOWED_ORIGINS: "http://localhost"
    DB_HOST: "database"
    DB_PORT: "5432"
    DB_DATABASE: "secureops"
    DB_USERNAME: "secureops"
    DB_PASSWORD: "<DB_PASSWORD>"

externalSecret:
  enabled: false
  # Secrets Manager secret ID created by Terraform: secureops/<env>/database
  # plus an app secret secureops/<env>/app for APP_KEY + URLs.
  refreshInterval: 1m
  storeName: aws-secretsmanager
  appSecretId: "secureops/staging/app"
  dbSecretId: "secureops/staging/database"

migrate:
  enabled: true
  backoffLimit: 3
  activeDeadlineSeconds: 300

ingress:
  enabled: true
  className: alb
  # ALB controller annotations. TLS fields activate only when domain + cert exist.
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /up
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
    alb.ingress.kubernetes.io/success-codes: 200-399
  host: ""
  # When host is empty the Ingress uses default ALB hostname (no TLS, no host rule).
  tls: []
```

## `charts/secureops/values-staging.yaml`

```yaml
global:
  env: staging

backend:
  replicaCount: 2
  image:
    repository: <ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/secureops-staging-backend
    tag: "sha-4ea08538f439"

frontend:
  replicaCount: 2
  image:
    repository: <ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/secureops-staging-frontend
    tag: "sha-4ea08538f439"

secrets:
  create: false # staging uses External Secrets (Secrets Manager), like prod

externalSecret:
  enabled: true
  appSecretId: "secureops/staging/app"
  dbSecretId: "secureops/staging/database"

ingress:
  host: "staging.shubham-shrestha.com.np"
  tls:
    - hosts: ["staging.shubham-shrestha.com.np"]
      secretName: app-tls
  annotations:
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: <ACM_CERT_ARN>
    alb.ingress.kubernetes.io/ssl-redirect: "443"
```

## `charts/secureops/values-prod.yaml`

```yaml
global:
  env: prod

backend:
  replicaCount: 3
  resources:
    requests: { cpu: 200m, memory: 512Mi }
    limits: { cpu: 1000m, memory: 1Gi }
  autoscaling:
    minReplicas: 3
    maxReplicas: 8

frontend:
  replicaCount: 3
  autoscaling:
    minReplicas: 3
    maxReplicas: 6

secrets:
  create: false # prod must use External Secrets, never values

externalSecret:
  enabled: true
  appSecretId: "secureops/prod/app"
  dbSecretId: "secureops/prod/database"

ingress:
  # host: app.example.com
  # tls:
  #   - hosts: [app.example.com]
  #     secretName: app-tls
  host: ""
  tls: []
```

## `charts/secureops/templates/_helpers.tpl`

```bash
{{/*
Common labels + names. Keep selectors stable across releases.
*/}}
{{- define "secureops.labels" -}}
helm.sh/chart: {{ include "secureops.chart" . }}
app.kubernetes.io/name: secureops
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "secureops.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "secureops.backendFullname" -}}
{{ .Release.Name }}-backend
{{- end }}

{{- define "secureops.frontendFullname" -}}
{{ .Release.Name }}-frontend
{{- end }}

{{- define "secureops.secretName" -}}
{{ .Release.Name }}-backend
{{- end }}
```

## `charts/secureops/templates/backend.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "secureops.backendFullname" . }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
    app.kubernetes.io/component: backend
spec:
  replicas: {{ .Values.backend.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
      app.kubernetes.io/component: backend
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: {{ .Release.Name }}
        app.kubernetes.io/component: backend
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 82
        fsGroup: 82
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: backend
          image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag }}"
          imagePullPolicy: {{ .Values.backend.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.backend.containerPort }}
          env:
            - { name: APP_ENV, value: {{ .Values.backend.env.APP_ENV | quote }} }
            - { name: APP_DEBUG, value: {{ .Values.backend.env.APP_DEBUG | quote }} }
            - { name: LOG_CHANNEL, value: {{ .Values.backend.env.LOG_CHANNEL | quote }} }
            - { name: LOG_LEVEL, value: {{ .Values.backend.env.LOG_LEVEL | quote }} }
            - { name: DB_CONNECTION, value: {{ .Values.backend.env.DB_CONNECTION | quote }} }
            - { name: SKIP_MIGRATIONS, value: {{ .Values.backend.env.SKIP_MIGRATIONS | quote }} }
            - name: APP_KEY
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: APP_KEY } }
            - name: APP_URL
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: APP_URL } }
            - name: FRONTEND_URL
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: FRONTEND_URL } }
            - name: CORS_ALLOWED_ORIGINS
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: CORS_ALLOWED_ORIGINS } }
            - name: DB_HOST
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_HOST } }
            - name: DB_PORT
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_PORT } }
            - name: DB_DATABASE
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_DATABASE } }
            - name: DB_USERNAME
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_USERNAME } }
            - name: DB_PASSWORD
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_PASSWORD } }
          livenessProbe:
            httpGet: { path: /up, port: http }
            initialDelaySeconds: 30
            periodSeconds: 30
          readinessProbe:
            httpGet: { path: /api/v1/health, port: http }
            initialDelaySeconds: 15
            periodSeconds: 15
          resources:
            {{- toYaml .Values.backend.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
            readOnlyRootFilesystem: false # Laravel needs storage/ writes; constrain via volume instead
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "secureops.backendFullname" . }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
    app.kubernetes.io/component: backend
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: backend
```

## `charts/secureops/templates/frontend.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "secureops.frontendFullname" . }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
spec:
  replicas: {{ .Values.frontend.replicaCount }}
  selector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
      app.kubernetes.io/component: frontend
  template:
    metadata:
      labels:
        app.kubernetes.io/instance: {{ .Release.Name }}
        app.kubernetes.io/component: frontend
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        fsGroup: 101
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: frontend
          image: "{{ .Values.frontend.image.repository }}:{{ .Values.frontend.image.tag }}"
          imagePullPolicy: {{ .Values.frontend.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.frontend.containerPort }}
          livenessProbe:
            httpGet: { path: /, port: http }
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet: { path: /, port: http }
            initialDelaySeconds: 5
            periodSeconds: 15
          resources:
            {{- toYaml .Values.frontend.resources | nindent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
            readOnlyRootFilesystem: true
          volumeMounts:
            # nginx pid + temp paths live under /tmp (see nginx-main.conf).
            # emptyDir keeps readOnlyRootFilesystem while giving scratch space.
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "secureops.frontendFullname" . }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
    app.kubernetes.io/component: frontend
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/component: frontend
```

## `charts/secureops/templates/migrate-job.yaml`

```yaml
{{- if .Values.migrate.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-migrate-{{ .Release.Revision }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
    app.kubernetes.io/component: migrate
  annotations:
    # Helm hook (helm upgrade path) + ArgoCD SyncWave (GitOps path) both run migrate first.
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
    argocd.argoproj.io/sync-wave: "-5"
spec:
  backoffLimit: {{ .Values.migrate.backoffLimit }}
  activeDeadlineSeconds: {{ .Values.migrate.activeDeadlineSeconds }}
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 82
        fsGroup: 82
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: migrate
          image: "{{ .Values.backend.image.repository }}:{{ .Values.backend.image.tag }}"
          imagePullPolicy: {{ .Values.backend.image.pullPolicy }}
          command: ["php", "artisan", "migrate", "--force", "--no-interaction"]
          env:
            - { name: APP_ENV, value: {{ .Values.backend.env.APP_ENV | quote }} }
            - { name: DB_CONNECTION, value: {{ .Values.backend.env.DB_CONNECTION | quote }} }
            - name: APP_KEY
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: APP_KEY } }
            - name: DB_HOST
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_HOST } }
            - name: DB_PORT
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_PORT } }
            - name: DB_DATABASE
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_DATABASE } }
            - name: DB_USERNAME
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_USERNAME } }
            - name: DB_PASSWORD
              valueFrom: { secretKeyRef: { name: {{ include "secureops.secretName" . }}, key: DB_PASSWORD } }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { cpu: 500m, memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
{{- end }}
```

## `charts/secureops/templates/secrets.yaml`

```yaml
{{- if .Values.secrets.create }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "secureops.secretName" . }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
type: Opaque
stringData:
  APP_KEY: {{ .Values.secrets.data.APP_KEY | quote }}
  APP_URL: {{ .Values.secrets.data.APP_URL | quote }}
  FRONTEND_URL: {{ .Values.secrets.data.FRONTEND_URL | quote }}
  CORS_ALLOWED_ORIGINS: {{ .Values.secrets.data.CORS_ALLOWED_ORIGINS | quote }}
  DB_HOST: {{ .Values.secrets.data.DB_HOST | quote }}
  DB_PORT: {{ .Values.secrets.data.DB_PORT | quote }}
  DB_DATABASE: {{ .Values.secrets.data.DB_DATABASE | quote }}
  DB_USERNAME: {{ .Values.secrets.data.DB_USERNAME | quote }}
  DB_PASSWORD: {{ .Values.secrets.data.DB_PASSWORD | quote }}
{{- end }}
---
{{- if .Values.externalSecret.enabled }}
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ include "secureops.secretName" . }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
  annotations:
    # Must sync BEFORE the migrate Job (wave -5): the Job needs this Secret.
    argocd.argoproj.io/sync-wave: "-10"
spec:
  refreshInterval: {{ .Values.externalSecret.refreshInterval }}
  secretStoreRef: { name: {{ .Values.externalSecret.storeName }}, kind: ClusterSecretStore }
  target: { name: {{ include "secureops.secretName" . }}, creationPolicy: Owner }
  dataFrom:
    - extract: { key: {{ .Values.externalSecret.appSecretId | quote }} }
    - extract: { key: {{ .Values.externalSecret.dbSecretId | quote }} }
{{- end }}
```

## `charts/secureops/templates/autoscaling.yaml`

```yaml
{{- if .Values.backend.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "secureops.backendFullname" . }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: {{ include "secureops.backendFullname" . }} }
  minReplicas: {{ .Values.backend.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.backend.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: {{ .Values.backend.autoscaling.targetCPUUtilizationPercentage }} } }
{{- end }}
---
{{- if .Values.backend.podDisruptionBudget.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "secureops.backendFullname" . }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
spec:
  minAvailable: {{ .Values.backend.podDisruptionBudget.minAvailable }}
  selector:
    matchLabels:
      app.kubernetes.io/instance: {{ .Release.Name }}
      app.kubernetes.io/component: backend
{{- end }}
---
{{- if .Values.frontend.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "secureops.frontendFullname" . }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: {{ include "secureops.frontendFullname" . }} }
  minReplicas: {{ .Values.frontend.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.frontend.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: {{ .Values.frontend.autoscaling.targetCPUUtilizationPercentage }} } }
{{- end }}
```

## `charts/secureops/templates/ingress.yaml`

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  labels:
    {{- include "secureops.labels" . | nindent 4 }}
  annotations:
    {{- toYaml .Values.ingress.annotations | nindent 4 }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  {{- if .Values.ingress.tls }}
  tls:
    {{- toYaml .Values.ingress.tls | nindent 4 }}
  {{- end }}
  rules:
    {{- if .Values.ingress.host }}
    - host: {{ .Values.ingress.host | quote }}
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service: { name: {{ include "secureops.backendFullname" . }}, port: { number: 80 } }
          - path: /
            pathType: Prefix
            backend:
              service: { name: {{ include "secureops.frontendFullname" . }}, port: { number: 80 } }
    {{- else }}
    - http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service: { name: {{ include "secureops.backendFullname" . }}, port: { number: 80 } }
          - path: /
            pathType: Prefix
            backend:
              service: { name: {{ include "secureops.frontendFullname" . }}, port: { number: 80 } }
    {{- end }}
{{- end }}
```

## `backend/Dockerfile`

```dockerfile
# Production Dockerfile for SecureOps Laravel API (EKS-ready).
# Multi-stage: vendor builds deps, runtime serves on 8080 as non-root www-data.
# No secrets baked in: config caching + migrations happen at runtime (entrypoint)
# or via Helm pre-upgrade Job when SKIP_MIGRATIONS=true.
# Port 8080 (not 80) so the image can run as non-root + read-only-ish on K8s.

FROM php:8.3-fpm-alpine AS vendor

# hadolint ignore=DL3018
# apk upgrade first: pulls patched OS libs (libexpat, pcre2) regardless of base snapshot age.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libzip-dev \
    unzip \
    git \
    oniguruma-dev \
    postgresql-dev \
    linux-headers

RUN docker-php-ext-install pdo_pgsql mbstring zip exif pcntl opcache \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www

# Layer cache: deps first, source second.
COPY composer.json composer.lock ./
RUN composer install --no-interaction --no-autoloader --no-scripts --no-dev --prefer-dist

COPY . .
# hadolint ignore=SC2015
RUN composer dump-autoload --optimize --no-dev \
    && composer check-platform-reqs --no-dev || true

FROM php:8.3-fpm-alpine AS runtime

WORKDIR /var/www

# hadolint ignore=DL3018
RUN apk upgrade --no-cache \
    && apk add --no-cache \
    nginx \
    supervisor \
    wget \
    libpng \
    libjpeg-turbo \
    freetype \
    libzip \
    libpq \
    oniguruma \
    && mkdir -p /var/log/supervisor /var/log/nginx /run/nginx /var/tmp/nginx /var/lib/nginx/logs /var/lib/nginx/tmp \
    && rm -f /etc/nginx/conf.d/default.conf /etc/nginx/http.d/default.conf

COPY --from=vendor /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=vendor /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/
COPY --from=vendor /usr/bin/composer /usr/bin/composer
COPY --from=vendor /var/www /var/www

COPY docker/php/opcache.ini /usr/local/etc/php/conf.d/opcache.ini
COPY docker/php/php.ini /usr/local/etc/php/conf.d/secureops.ini
COPY docker/nginx/default.conf /etc/nginx/http.d/default.conf
COPY docker/supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chown -R www-data:www-data /var/www/storage /var/www/bootstrap/cache /var/log/nginx /var/log/supervisor /run/nginx /var/tmp/nginx /var/lib/nginx \
    && chmod -R ug+rwx /var/www/storage /var/www/bootstrap/cache

# Non-root from here on. K8s securityContext should still set runAsNonRoot: true.
USER www-data

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/up | grep -q "OK" || wget -qO- http://127.0.0.1:8080/up | grep -q '"status"' || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

## `backend/.dockerignore`

```gitignore
.git
.gitignore
.env
.env.local
vendor
node_modules
storage/logs/*
storage/framework/cache/*
storage/framework/sessions/*
storage/framework/views/*
bootstrap/cache/*.php
.phpunit.cache
.phpunit.result.cache
coverage
```

## `backend/docker/entrypoint.sh`

```bash
#!/bin/sh
set -eu

# Entrypoint: wait for DB, optionally migrate, cache config, exec supervisor.
# EKS/Helm pattern: set SKIP_MIGRATIONS=true in Deployment so a Helm
# pre-upgrade Job owns migrations (avoids parallel migrate races on scale-out).
# Local compose: leave SKIP_MIGRATIONS unset so `docker compose up` just works.

DB_HOST="${DB_HOST:-database}"
DB_PORT="${DB_PORT:-5432}"
MAX_ATTEMPTS="${DB_WAIT_ATTEMPTS:-30}"
SKIP_MIGRATIONS="${SKIP_MIGRATIONS:-false}"

echo "Waiting for database ${DB_HOST}:${DB_PORT}..."
attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  if php -r "\$c=@fsockopen(getenv('DB_HOST')?:'database',(int)(getenv('DB_PORT')?:5432)); if(\$c){fclose(\$c); exit(0);} exit(1);"; then
    echo "Database reachable."
    break
  fi
  echo "Attempt ${attempt}/${MAX_ATTEMPTS}: database not ready, sleeping 2s..."
  sleep 2
  attempt=$((attempt+1))
done

if [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
  echo "Database never became ready; continuing anyway (migrate may fail)."
fi

cd /var/www

mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views \
  storage/logs bootstrap/cache

# APP_KEY must come from Secrets Manager / K8s Secret in prod. Ephemeral fallback is dev-only.
if [ -z "${APP_KEY:-}" ] || [ "${APP_KEY:-}" = "base64:" ]; then
  echo "APP_KEY missing; generating ephemeral key (set APP_KEY in production)."
  GENERATED_KEY=$(php artisan key:generate --show 2>/dev/null || true)
  if [ -n "${GENERATED_KEY:-}" ]; then
    export APP_KEY="$GENERATED_KEY"
    echo "Ephemeral APP_KEY generated for this container run."
  else
    echo "WARNING: could not generate APP_KEY; encryption-dependent features may fail."
  fi
fi

if [ "$SKIP_MIGRATIONS" = "true" ]; then
  echo "SKIP_MIGRATIONS=true — skipping migrate (Helm Job owns it)."
else
  php artisan migrate --force --no-interaction || {
    echo "Migration failed; check DB credentials."
    exit 1
  }
fi

if [ "${APP_ENV:-production}" = "production" ]; then
  php artisan config:cache || true
  php artisan route:cache || true
  php artisan view:cache || true
else
  php artisan config:clear || true
  php artisan route:clear || true
  php artisan view:clear || true
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
```

## `backend/docker/nginx/default.conf`

```nginx
server {
    # 8080 so the container can run as www-data (non-root). K8s Service targets 8080.
    listen 8080 default_server;
    server_name _;

    root /var/www/public;
    index index.php;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Block dotfiles (.git, .env)
    location ~ /\. {
        deny all;
    }

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri $uri/ /index.php?$query_string;
    }

    access_log /dev/stdout;
    error_log /dev/stderr warn;
}
```

## `backend/docker/php/php.ini`

```ini
; Production PHP tuning for SecureOps API (extends opcache.ini).
expose_php=Off
max_execution_time=30
memory_limit=256M
post_max_size=8M
upload_max_filesize=8M
max_file_uploads=10
allow_url_fopen=Off
display_errors=Off
display_startup_errors=Off
log_errors=On
error_reporting=E_ALL & ~E_DEPRECATED & ~E_STRICT
date.timezone=UTC
session.cookie_httponly=1
session.cookie_samesite=Lax
session.use_strict_mode=1
; Log to stderr so CloudWatch / kubectl logs pick it up without a sidecar.
error_log=/dev/stderr
```

## `backend/docker/php/opcache.ini`

```ini
[opcache]
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=2
opcache.validate_timestamps=0
opcache.save_comments=1
opcache.fast_shutdown=1
```

## `backend/docker/supervisor/supervisord.conf`

```nginx
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/tmp/supervisord.pid

[program:php-fpm]
command=php-fpm -F
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
priority=5

[program:nginx]
command=nginx -g "daemon off;"
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
autorestart=true
priority=10
```

## `frontend/Dockerfile`

```dockerfile
# Production Dockerfile for SecureOps React frontend (EKS-ready).
# Stage 1 builds the Vite bundle; stage 2 serves it via nginx on 8080 as non-root.
# Same-origin /api proxy is for local compose only — on EKS the Ingress routes
# /api/* to the backend Service, so this proxy is a fallback.
FROM node:20-alpine AS build

# Patched OS libs (libexpat, pcre2) regardless of base snapshot age.
RUN apk upgrade --no-cache

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .
RUN npm run build

FROM nginx:stable-alpine AS runtime

COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY nginx-main.conf /etc/nginx/nginx.conf

# nginx:stable-alpine runs as root by default; use unprivileged port + user.
# 8080 matches backend convention and K8s non-root policy.
RUN apk upgrade --no-cache \
    && sed -i 's/listen 80 /listen 8080 /g' /etc/nginx/conf.d/default.conf \
    && mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp \
    && chown -R nginx:nginx /usr/share/nginx/html /etc/nginx/conf.d /etc/nginx/nginx.conf /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp \
    && chmod -R u+rX /usr/share/nginx/html

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/ | grep -q "SecureOps" || exit 1

CMD ["nginx", "-g", "daemon off;"]
```

## `frontend/.dockerignore`

```gitignore
node_modules
dist
coverage
.git
.gitignore
.env
.env.local
*.log
.vscode
.idea
```

## `frontend/nginx.conf`

```nginx
server {
    listen 8080 default_server;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self';" always;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;
    gzip_min_length 1024;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Cache versioned assets aggressively; never cache index.html.
    location = /index.html {
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        try_files $uri =404;
    }

    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable" always;
        try_files $uri =404;
    }

    # Local-compose fallback only: on EKS the Ingress routes /api/* to the
    # backend Service, so this block is never hit there. Variable + resolver
    # so nginx still starts where "backend" DNS doesn't exist (e.g. K8s).
    location /api/ {
        resolver 127.0.0.11 10.96.0.10 valid=10s;
        set $backend_upstream http://backend:8080;
        proxy_pass $backend_upstream;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 5s;
        proxy_send_timeout 15s;
        proxy_read_timeout 15s;
    }
}
```

## `frontend/nginx-main.conf`

```nginx
# Main context tuned for running as the unprivileged nginx user (no root).
# All writable paths live under /tmp so neither docker nor K8s needs
# extra volumes or init steps. Server blocks stay in conf.d/default.conf.
user nginx;
worker_processes auto;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /dev/stdout;
    error_log /dev/stderr warn;

    client_body_temp_path /tmp/client_temp;
    proxy_temp_path /tmp/proxy_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;

    sendfile on;
    keepalive_timeout 65;

    include /etc/nginx/conf.d/*.conf;
}
```

## `ops/sleep.sh`

```bash
#!/bin/sh
# Sleep the showcase stack: nodes to 0, RDS stopped.
# Burn asleep ~= $100/mo (EKS + ALB + WAF + storage). Nothing is deleted:
# ECR images, secrets, DNS, ACM cert, Terraform state all untouched.
# Idempotent: safe to re-run anytime. See docs/sleep-wake.md.
set -eu

REGION="${AWS_REGION:-ap-south-1}"
CLUSTER="${CLUSTER_NAME:-secureops-staging}"
DB="${DB_INSTANCE:-secureops-staging}"
NAMESPACE="${NAMESPACE:-secureops-staging}"
LOG="${POWER_LOG:-$HOME/logs/secureops-power.log}"

log() { printf '%s [sleep] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

mkdir -p "$(dirname "$LOG")"
DRY_RUN="${1:-}"
if [ "$DRY_RUN" = "--dry-run" ]; then
  log "dry-run: would scale nodegroup to 0 and stop RDS $DB"
  exit 0
fi

# Pre-flight: valid AWS auth (fails fast on clock skew).
aws sts get-caller-identity --region "$REGION" >/dev/null \
  || die "AWS auth failed (check clock: date -u, then sudo chronyc -a makestep)"

NG=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'nodegroups[0]' --output text) || die "cannot list nodegroups"
[ -z "$NG" ] || [ "$NG" = "None" ] && die "no nodegroup found for $CLUSTER"
log "nodegroup: $NG"

# 1. Drain compute. Never kubectl-scale Deployments: ArgoCD self-heal owns
# pod counts and would revert it. Nodegroup to 0 is invisible to GitOps.
log "scaling nodegroup desired to 0..."
aws eks update-nodegroup-config --cluster-name "$CLUSTER" \
  --nodegroup-name "$NG" --region "$REGION" \
  --scaling-config minSize=0,maxSize=4,desiredSize=0 >/dev/null \
  || die "nodegroup scale-down rejected"

# 2. Stop the database. NOTE: AWS auto-restarts stopped RDS after 7 days.
log "stopping RDS $DB (tolerating already-stopped)..."
if ! aws rds stop-db-instance --db-instance-identifier "$DB" --region "$REGION" >/dev/null 2>&1; then
  log "stop call refused (likely already stopped) — continuing"
fi

# 3. Confirm.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
log "waiting for nodes to drain (10 min max)..."
deadline=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -z "$(kubectl get nodes --no-headers 2>/dev/null)" ]; then break; fi
  sleep 20
done
[ -z "$(kubectl get nodes --no-headers 2>/dev/null)" ] \
  || die "nodes still present after 10 min"

STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DB" \
  --region "$REGION" --query 'DBInstances[0].DBInstanceStatus' --output text)
[ "$STATUS" = "stopped" ] || [ "$STATUS" = "stopping" ] \
  || die "RDS status is $STATUS, expected stopped/stopping"

log "DONE asleep. Burn ~= \$100/mo. Wake with ops/wake.sh (~15 min)."
```

## `ops/wake.sh`

```bash
#!/bin/sh
# Wake the showcase stack: RDS started, nodes to 3, full verification.
# Expected lead time ~15 min. Exit non-zero naming the failed stage.
# See docs/sleep-wake.md.
set -eu

REGION="${AWS_REGION:-ap-south-1}"
CLUSTER="${CLUSTER_NAME:-secureops-staging}"
DB="${DB_INSTANCE:-secureops-staging}"
NAMESPACE="${NAMESPACE:-secureops-staging}"
SITE="${SITE_URL:-https://staging.shubham-shrestha.com.np}"
LOG="${POWER_LOG:-$HOME/logs/secureops-power.log}"

log() { printf '%s [wake] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }
wait_until() { # wait_until <seconds> <description> <command...>
  secs=$1; desc=$2; shift 2
  deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then log "$desc OK"; return 0; fi
    sleep 20
  done
  die "$desc timed out after ${secs}s"
}

mkdir -p "$(dirname "$LOG")"
if [ "${1:-}" = "--dry-run" ]; then
  log "dry-run: would start RDS $DB and scale nodegroup to 3, then verify"
  exit 0
fi

aws sts get-caller-identity --region "$REGION" >/dev/null \
  || die "AWS auth failed (check clock: date -u, then sudo chronyc -a makestep)"

NG=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'nodegroups[0]' --output text) || die "cannot list nodegroups"
[ -z "$NG" ] || [ "$NG" = "None" ] && die "no nodegroup found for $CLUSTER"

# 1. Database first (pods need it on boot).
log "starting RDS $DB (tolerating already-available)..."
aws rds start-db-instance --db-instance-identifier "$DB" --region "$REGION" >/dev/null 2>&1 \
  || log "start call refused (likely already available) — continuing"
wait_until 900 "RDS available" sh -c \
  "[ \"\$(aws rds describe-db-instances --db-instance-identifier \"$DB\" --region \"$REGION\" --query DBInstances[0].DBInstanceStatus --output text)\" = available ]"

# 2. Compute.
log "scaling nodegroup to desired 3..."
aws eks update-nodegroup-config --cluster-name "$CLUSTER" \
  --nodegroup-name "$NG" --region "$REGION" \
  --scaling-config minSize=2,maxSize=4,desiredSize=3 >/dev/null \
  || die "nodegroup scale-up rejected"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
wait_until 720 "3 nodes Ready" sh -c \
  "[ \"\$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')\" -ge 3 ]"
wait_until 720 "app pods Running" sh -c \
  "[ \"\$(kubectl -n \"$NAMESPACE\" get pods --no-headers 2>/dev/null | grep -cv 'Running')\" -eq 0 ]"

# 3. User-facing proof (demo-login shape check posts bad creds on purpose:
# a 422 ValidationException proves the API + DB path works end to end).
wait_until 300 "API health 200" sh -c \
  "[ \"\$(curl -s -m 15 -o /dev/null -w '%{http_code}' \"$SITE/api/v1/health\")\" = 200 ]"
[ "$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$SITE/")" = 200 ] \
  || die "SPA root did not return 200"
CODE=$(curl -s -m 15 -X POST "$SITE/api/v1/login" -H 'Content-Type: application/json' \
  -d '{"email":"nobody@example.invalid","password":"wrongwrong00"}' -o /dev/null -w '%{http_code}')
[ "$CODE" = "422" ] || die "login-shape check returned $CODE, expected 422"

log "DONE LIVE — shareable. Burn ~= \$199/mo while awake."
```

## `docs/sleep-wake.md`

```markdown
# Sleep / Wake runbook — SecureOps showcase env

- Owner: platform (Shubham). Last tested: 2026-10-08 (full supervised sleep→wake, ~8 min wake).
- Sleep: ~5 min → burn **~$100/mo**. Wake: ~15 min → burn **~$199/mo**, link shareable.
- Rule: wake the stack *before* submitting applications or interviews, never during.

## Preconditions (every run)

```bash
export KUBECONFIG=~/.kube/config   # local kubectl defaults to k3s otherwise
date -u                            # must match real UTC; if skewed: sudo chronyc -a makestep
aws sts get-caller-identity --region ap-south-1
```

## Sleep (`sh ops/sleep.sh [--dry-run]`)

1. Pre-flight AWS auth — aborts on clock skew. Never proceed half-authenticated.
2. Nodegroup `desired 0` via AWS API (`min 0/max 4`). **Never `kubectl scale` Deployments** — ArgoCD self-heal owns pod counts and reverts it.
3. `stop-db-instance`. AWS auto-restarts stopped RDS after **7 days** — sleeping longer requires re-running sleep weekly.
4. Confirm: `kubectl get nodes` empty, RDS `stopped`, site URL returns **503/504 with resolving DNS** (ALB alive, no targets = paused, not broken).
5. Log line appended to `~/logs/secureops-power.log`.

## Wake (`sh ops/wake.sh [--dry-run]`)

1. Same pre-flight → `start-db-instance`, wait `available` (15-min timeout).
2. Nodegroup `desired 3` → wait 3 nodes Ready + 4/4 app pods Running (12-min timeout).
3. Proof: HTTPS `/api/v1/health` 200, SPA `/` 200, login-shape POST returns **422** (bad creds rejected = API+DB path proven end to end; no token created).
4. Prints `DONE LIVE`. Only then share the link.

## Verification (Layer 1–3)

```bash
kubectl -n argocd get applications            # Synced (health flag cosmetic, see quirks)
kubectl -n secureops-staging get pods         # 4/4 Running
curl -s -o /dev/null -w "%{http_code}\n" https://staging.shubham-shrestha.com.np/api/v1/health
```

## Guardrails

- No `terraform apply` while asleep (it would revive nodes as a side effect).
- Node desired-count is API-managed by design (upstream EKS module `ignore_changes`); Terraform owns type + min/max only.
- Sleep never touches: ECR images, Secrets Manager, DNS, ACM cert, Terraform state, WAF rules.
- Alarms may flap while asleep (silent — no email configured).

## Known quirks (hit during setup)

- Alma clock drifts when the VM suspends → all AWS signatures fail. Fix with sudo chronyc; NTP discipline recommended.
- `t3.small` fits only as 3 nodes: 11 pods/node ENI limit vs 26 cluster pods (ArgoCD alone is 7).
- ArgoCD `Degraded` flag with zero unhealthy resources is a v3.5.3 display quirk; sync/pods/endpoints are the real signals.
```

## `docs/backup-restore.md`

```markdown
# Backup & restore — SecureOps RDS Postgres

- Last drilled: 2026-10-12 (snapshot → temp instance → row-count match → destroy).
- Live data changes; the drill procedure below re-verifies on demand.

## What protects the data

- Automated daily snapshots, 02:00–03:00 UTC window, 1-day retention
  (staging cost choice; prod template uses 7 days + Multi-AZ).
- Storage encrypted at rest (gp3). Manual snapshot `secureops-drill-20261012`
  retained as the drill artifact (billed on actual usage, cents).
- Secrets Manager holds DB creds; ECR images are immutable — the database
  is the only stateful component, hence the only restore target.

## Restore drill (safe: never touches the live instance)

```bash
REGION=ap-south-1
# 1. Fingerprint live data (counts only, no dump leaves the cluster).
kubectl -n secureops-staging exec deploy/secureops-staging-backend -- \
  php artisan tinker --execute='echo "users=".App\Models\User::count().",contacts=".App\Models\Contact::count().PHP_EOL;'

# 2. Manual snapshot of live.
aws rds create-db-snapshot --db-instance-identifier secureops-staging \
  --db-snapshot-identifier secureops-drill-$(date +%Y%m%d) --region $REGION
#    wait: Status available

# 3. Restore to a DISPOSABLE instance. Network flags are REQUIRED:
#    restore defaults to the default VPC (unreachable from EKS) otherwise.
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier secureops-drill-verify \
  --db-snapshot-identifier <snapshot-id> \
  --db-instance-class db.t3.micro \
  --db-subnet-group-name secureops-staging \
  --vpc-security-group-ids <rds-sg-id> \
  --no-multi-az --no-publicly-accessible --region $REGION
#    wait: Status available (~10 min)

# 4. Verify row counts from an ephemeral psql pod (auto-deleted, --rm).
#    Password via Secrets Manager, never pasted.
kubectl -n secureops-staging run psql-drill --rm -i --restart=Never \
  --image=postgres:16-alpine --env="PGPASSWORD=<from-secret>" -- \
  psql -h <drill-endpoint> -U <user> -d <db> -tAc \
  "SELECT 'users='||(SELECT count(*) FROM users)||',contacts='||(SELECT count(*) FROM contacts);"
#    expected: identical to step 1.

# 5. Destroy the disposable instance (keep the snapshot).
aws rds delete-db-instance --db-instance-identifier secureops-drill-verify \
  --skip-final-snapshot --region $REGION
```

## Gotchas recorded 2026-10-12

- Restore without `--db-subnet-group-name`/`--vpc-security-group-ids`
  lands in the default VPC → connection timeouts from EKS pods.
- Real disaster path (live instance lost): same flow, but restore with the
  production identifier + update `secureops/<env>/database` `DB_HOST` in
  Secrets Manager; ESO syncs it to pods within a minute, no redeploy needed.
- PITR uses the same verify/destroy pattern with
  `restore-db-instance-to-point-in-time` instead of step 3.
```
