# Part III — Infrastructure and cloud

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

All paths under `infra/terraform/`. Region `ap-south-1`; name prefix
`secureops-<env>` (live env: `staging`). Conventions: every resource tagged
`Project/Environment/ManagedBy` (`versions.tf` default_tags).

## 4.1 Providers, versions, state (`versions.tf`, `backend.tf`)

`versions.tf` pins Terraform `>=1.6`, AWS provider `~>5.60`, Helm `~>2.14`,
and configures the Helm provider to talk to EKS via `aws eks get-token`
(exec auth) — i.e., Terraform drives *both* AWS APIs and the cluster's Helm
releases from your laptop credentials. `.terraform.lock.hcl` is committed
(reproducible provider binaries); `.terraform/` (binaries+cache) is gitignored.

`backend.tf` points state at S3 (`secureops-tfstate-<account-id>`,
key `secureops/eks/terraform.tfstate`, DynamoDB locks, encrypted).
Why this matters: state holds the RDS password and is the only map of
managed resources. Losing it = `terraform plan` wants to recreate the world;
leaking it = leaking DB creds. FACT: this repo's backend block was once
commented out (local state) and later activated — the migration path was
`init -migrate-state`.

READ-ONLY: `terraform -chdir=infra/terraform validate | fmt -check -recursive`
(`make tf-validate` runs all three with `init -backend=false`).

## 4.2 Network (`network.tf`)

One VPC `10.0.0.0/16`, `az_count` AZs (2 staging, 3 prod-template), public +
private subnets, one NAT per staging (`single_nat_gateway=true`) vs per-AZ in
prod. Mandatory subnet tags (`kubernetes.io/role/elb|internal-elb`) let the
LB Controller discover where to place the ALB — delete those tags and
Ingress provisioning fails opaquely (Ch. 10). Pods/nodes live private;
only the ALB + NAT have public faces. Cost note: each NAT ≈ $35/mo + data
processing — the single largest "invisible" line after EKS itself.

## 4.3 EKS (`eks.tf`, `staging.tfvars`)

Module `terraform-aws-modules/eks/aws ~>20.8`: control plane v1.32
(`eks_version`; 1.30 AMIs were deleted upstream — the 400 that started our
hardening saga, Ch. 10), private subnets, public endpoint enabled,
creator-admin on. Managed node group `default`: `t3.small ×3` (was 2×medium;
pod-density math forced 3 smalls — 11 pods/node ENI cap vs 26 cluster pods,
Ch. 12), 30GB gp3 disks, EBS-CSI IRSA for volume ops.

Critical module behavior: `lifecycle ignore_changes = [scaling_config[0].
desired_size]` — Terraform manages type/min/max; **live desired count is
API-managed** (documented in `staging.tfvars`; Cluster Autoscaler compat).
`terraform plan` will never show desired drift. Scale via
`aws eks update-nodegroup-config` (see `ops/wake.sh`), not tfvars.

Node IAM: nodes get ECR-pull + CNI/CIDR rights only. Pod permissions come
from IRSA roles (LB controller, EBS-CSI, ESO), never the node role (Ch. 3.12).

## 4.4 Database (`rds.tf`)

`aws_db_instance`: Postgres 16, `db.t3.micro`, 20GB→100 autoscale gp3,
encrypted, private subnets, publicly inaccessible, SG allows :5432 **only
from the node SG** (`rds.tf:6-25`). Staging: single-AZ, 1-day retention,
no deletion protection, no Performance Insights; prod-template flips all four
(`multi_az`, 7-day, deletion protection, PI). Password: `random_password`
→ instance + `aws_secretsmanager_secret_version` (`…/staging/database` with
`DB_HOST/PORT/DATABASE/USERNAME/PASSWORD` JSON). FACT: only `/database` is
Terraform-managed; `/app` (`APP_KEY`, URLs) was created by hand — a documented
asymmetry; rotate either via console + ESO picks it up in ≤1 min.

Deletion safety: `skip_final_snapshot = var.env != "prod"` — destroying
staging takes no final snapshot. Know this before any `destroy`.

## 4.5 Registry (`ecr.tf`)

Two repos (`…-backend`, `…-frontend`): `IMMUTABLE` tags (a tag can never be
overwritten — the foundation of rollback-by-revert), scan-on-push (AWS-side
backstop behind Trivy), AES256, keep-last-20 lifecycle. Deleted-by-us history:
pre-gate vulnerable tags + floating `latest` were `batch-delete-image`d;
immutability blocks overwrite, never delete. INFERENCE: untagged attestation
manifests accumulate — lifecycle handles them.

## 4.6 GitHub OIDC (`iam-github-oidc.tf`) — read twice

Creates (first run, empty `github_repo`) or references (steady state) the
account OIDC provider `token.actions.githubusercontent.com`, then a role
`secureops-<env>-github-release` whose trust requires `aud=sts.amazonaws.com`
**and** `sub` matching `repo:<owner>@*/<repo>@*:*`. Three hard-won details,
each an outage in Ch. 10:

1. `sub` embeds numeric IDs (`OWNER@id/REPO@id:ref:…`) — legacy `OWNER/REPO:*`
   patterns never match. Diagnose by decoding the JWT (procedure in Ch. 10).
2. Provider **thumbprints**: GitHub's serving chain moved to Let's Encrypt
   (`leaf ← YR2 ← Root YR`, ISRG-anchored). The list carries Root-YR
   cross-sign + ISRG Root X1 + legacy thumbprint; AWS matches any entry.
3. First-run transition used `terraform state rm` on the self-created provider
   (only one GitHub provider may exist per account) — data source since.
   `github_release_ecr` policy: push + pull (`GetDownloadUrlForLayer` was the
   missing piece that broke Trivy pulls).

## 4.7 Cluster add-ons (`addons.tf`, `eso-irsa.tf`)

- **LB Controller 1.7.2** (Helm, IRSA `attach_load_balancer_controller_policy`,
  `wait=true`): watches Ingress objects, provisions/configures the ALB.
  Serialized *before* ESO (`depends_on`) — parallel install caused the
  webhook `no endpoints` failure (Ch. 10).
- **External Secrets 0.10.4** (`wait`, 600s timeout, SA annotated with the
  ESO role): `eso-irsa.tf` grants `GetSecretValue/DescribeSecret` on
  `secureops/{staging,prod}/*` to SA `external-secrets:external-secrets`.
  `ClusterSecretStore` (`argocd/clustersecretstore.yaml`) + per-release
  `ExternalSecret` (chart) complete the chain. Restart pods after (re)annotation
  — IRSA env arrives only at pod start (Ch. 10).

## 4.8 WAF + alarms (`waf.tf`, `alarms.tf`, `variables.tf:alert_email`)

WAFv2 Regional ACL associated to the controller-created ALB (looked up by
`elbv2.k8s.aws/cluster` tag): CommonRuleSet + KnownBadInputs (override `none`
= AWS-managed blocking), IP rate-limit 3000/5min shielding `/login`.
Default ALLOW + sampled requests → tune from CloudWatch metrics, not guesses.
Alarms: RDS CPU>80%, free storage <5GiB, ALB 5xx sum>20/10min → SNS topic;
email subscription exists only if `alert_email` is set (currently unset —
alarms are silent records). Cost: WAF ~$5/mo + request fees; alarms $0.10 each.

## 4.9 Variables, outputs, plan/apply/inspect

`variables.tf` (+ `staging.tfvars` live / `prod.tfvars` template):
`project/env/region`, `vpc_cidr`, `az_count`, `eks_version`,
node group shape, `db_*`, `domain_name` (empty = ALB-hostname mode),
`github_repo`, `alert_email`. `outputs.tf`: cluster name/endpoint/OIDC,
both ECR URLs, RDS endpoint, DB secret ARN, release role ARN (→ GHA vars).

Lifecycle commands (labels per Ch. 1 conventions):

- READ-ONLY: `terraform plan -var-file=staging.tfvars` (always before apply);
  `terraform state list | grep <name>`; `terraform output`.
- STATE-CHANGING: `apply` (node replacement drains 8+ min — watch pods);
  `apply -target=module.eks` (recorded pattern for cluster-only surgery).
- DESTRUCTIVE: `destroy` (staging takes **no final RDS snapshot** — snapshot
  manually first; S3 state bucket is *not* managed here and survives).
- Drift: `plan` empty + `ignore_changes(desired_size)` + WAF-association
  re-created every plan (harmless no-op re-association; data-source `one()`
  over a set re-resolves each run).
- Recovery: state is versioned in S3; corrupted workspace → fresh clone +
  `init -reconfigure` re-downloads providers, state untouched.

Managed alternatives + trade-offs: Fargate (no nodes to size, but $73 EKS fee
remains + per-pod pricing + slower cold starts); RDS → Aurora Serverless
(2×+ cost at idle); ALB → NLB (cheaper, loses WAF + path routing). None beat
this shape at demo scale with HA requirements — details in Ch. 12.
