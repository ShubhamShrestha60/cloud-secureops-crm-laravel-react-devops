# Part X — Lifecycle, disaster recovery, and cost

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

## 10.1 Setup and rebuild (clean-machine path)

Prereqs: AWS account + bootstrap IAM user (MFA on), GitHub account, tools
(`aws`, `terraform ≥1.6`, `kubectl`, `helm`, `docker`), region `ap-south-1`.

1. Clone repo; `aws configure`; `aws sts get-caller-identity` (note account).
2. S3 state bucket + DynamoDB lock table (one-time CLI; names in `backend.tf`
   pattern) → uncomment `backend.tf` → `init -migrate-state` as needed.
3. `staging.tfvars`: set `github_repo`; `plan` → `apply` (~25 min: VPC 1,
   EKS 12–15, nodes 6–8, RDS 5–10 parallel).
4. `terraform output` → ECR URLs into `values-staging.yaml`; role ARN → GHA
   Variables (`AWS_REGION`, `AWS_ROLE_TO_ASSUME`, `ECR_*`).
5. Create `secureops/<env>/app` secret (Terraform makes only `/database`).
6. Push → green Release → pin tags → `argocd/bootstrap.sh` (+ repo PAT secret
   for private repos; server-side CRD apply if the annotation-too-long error
   appears) → ArgoCD syncs → seed admin explicitly → verify Layer 1–3 + demo
   login → ACM cert + CNAMEs → HTTPS verify.
Each step's failure modes are Ch. 10 entries; total rebuild ≈ 2–3 h attended.

## 10.2 Maintenance and recovery

- Updates: image bumps via Release+pin (routine); EKS minor upgrades are
  **stepwise only** (1.30→1.31→1.32, never跳 — never skip); base-image/Terraform
  provider bumps via Dependabot PRs with CI gates; `terraform apply` only when
  awake (sleep guardrail).
- Backups: RDS daily auto (1-day staging) + retained manual drill snapshots;
  state versioned in S3; ECR immutable; SM unversioned (rotate carefully).
- Partial-operation recovery: failed `apply` → read state + `plan` before
  re-running (never `destroy` a half-built stack in panic); failed Helm
  release → `helm list -a` → uninstall + re-apply; stuck ArgoCD sync → Ch. 10 T6
  tree.
- Rollback: app = revert tag pin; schema = manual (no down-migration
  automation — design migrations additively); infra = revert tfvars + apply
  (node type changes replace nodes with drain).
- Periodic tests (calendar): backup drill (done 2026-10-12, repeat on schema
  milestones), sleep/wake cycle (stamped 2026-10-08), alarm fire check,
  cert-expiry-30d check, Dependabot PR throughput.

## 10.3 Teardown (ordered, with costs of forgetting)

Order: ArgoCD Applications → (`terraform destroy`; snapshot RDS manually
first — staging takes none) → confirm ALB/nodes/RDS/WAF gone → keep S3 state,
ECR images, manual snapshots, SM secrets until explicitly released → watch
billing → ~$0 within 48h. Orphans to hunt: unattached EIPs/volumes/snapshots,
failed ACM validations (free but confusing), DynamoDB lock table (pennies;
keep for rebuilds). Destroying the state bucket is a separate deliberate act —
never part of routine teardown. Full procedure with commands: Ch. 9 §12.

## 10.4 Cost management (measured, not estimated)

Method: Billing API monthly-by-service (`us-east-1` endpoint even for
Mumbai spend) + `describe-*` inventory; fixed vs usage split below. FACTS:
project born Oct 2; steady burn ≈ **$199/mo awake** (EKS $73, nodes 3×small
$45, NAT $35, ALB $18, RDS $15, disks ~$8, WAF $5, smalls ~$2–3), **~$100/mo
asleep** (EKS+ALB+WAF+storage persist). Second ALB would add ~$18/mo
(declined). Stopped `t3.micro`s terminated; vulnerable ECR tags deleted.

| Lever | Saves | Trade-off |
|---|---|---|
| Sleep/wake (`ops/`) | ~$115/mo per asleep month | Link 503/504 while asleep; 15-min lead; RDS 7-day auto-wake |
| 3×small (done) vs 2×medium | ~$16/mo kept | Thinner memory margin (Ch. 12) |
| Single NAT (done) | ~$35/mo vs per-AZ | AZ-failure egress degradation |
| RDS micro/1-day (done) | ~50% vs small/7-day | No HA, thin backup window |
| Hibernate (destroy) | ~$195/mo | Dead link, 25-min revive + statedbilty |
| Lean-host migration (declined) | ~$190/mo | Abandons managed-K8s story |

Regional note: Mumbai pricing used throughout; moving regions moves every
line ±10–20% and breaks ACM/ALB co-location assumptions. Budget alarms must
be re-tuned after every sizing change (ours outgrew $20 on day one).
Rightsizing loop: requests/limits math (no metrics-server) → change →
soak → record. Never present estimates as bills: method + assumptions travel
with every number.
