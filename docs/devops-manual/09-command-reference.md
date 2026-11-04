# Part VIII — Command reference

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

Conventions: `export KUBECONFIG=~/.kube/config` precedes every kubectl/helm
invocation on hosts with stacked kubeconfigs (see Ch. 10). `--region
ap-south-1` is required on AWS calls outside configured defaults. Labels:
**READ-ONLY** (safe anytime), **STATE-CHANGING** (creates/mutates),
**DESTRUCTIVE** (deletes/loses — double-check identifiers aloud).

## 1. Installation & prerequisites

- `aws --version`, `terraform -chdir=infra/terraform version`,
  `kubectl version --client`, `helm version`, `docker --version` —
  READ-ONLY. Run once per machine; record in environment notes. Mismatch
  symptom: unknown subcommands (e.g., old `aws` lacking newer EKS APIs).
- `aws configure --region ap-south-1` — STATE-CHANGING (writes
  `~/.aws/credentials`). Needs bootstrap IAM keys; prefer SSO/OIDC where
  offered. Verify with `aws sts get-caller-identity` (READ-ONLY).

## 2. Authentication & configuration

- `aws sts get-caller-identity` — READ-ONLY. Expected: your user ARN +
  account. Fails on clock skew (`InvalidSignatureException` → fix clock, Ch. 10).
- `aws eks update-kubeconfig --name secureops-staging --region ap-south-1` —
  STATE-CHANGING (rewrites `~/.kube/config`). Then `kubectl cluster-info` +
  `get nodes` must show EKS nodes, never `localhost.localdomain` (k3s shim!).
- `kubectl config current-context` — READ-ONLY. Must be the
  `arn:aws:eks:…:secureops-staging` context before any cluster write.

## 3. Validation (pre-change gates)

- `terraform validate | fmt -check -recursive` (`make tf-validate` adds
  `init -backend=false`) — READ-ONLY. Run before every plan.
- `terraform plan -var-file=staging.tfvars` — READ-ONLY. Read adds/changes/
  destroys; question any destroy. Known noise: WAF association re-created
  each plan (harmless); node `desired_size` never diffs (API-managed, Ch. 4).
- `helm template … -f values.yaml -f values-staging.yaml -n secureops-staging
  [--show-only templates/X.yaml]` — READ-ONLY. Required before chart pushes;
  grep `image:` and `kind:` lines as a smoke check.
- `docker build ./backend|./frontend` — READ-ONLY locally (writes only local
  cache). Catches lock/platform and nginx-config errors pre-CI.
- `composer validate`, `composer audit` (via `composer:2` container if no PHP)
  — READ-ONLY. Audit must print zero advisories before Release can pass.

## 4. Inspection & status

- `kubectl -n <ns> get pods|deploy|svc|ingress|externalsecret|job` —
  READ-ONLY. `-o yaml` for full objects; `-o jsonpath` for scripts.
- `kubectl -n argocd get applications` — READ-ONLY. Want `Synced`; health flag
  has a known cosmetic failure mode (Ch. 8/10) — corroborate with pods + curl.
- `aws eks describe-nodegroup …`, `aws rds describe-db-instances …`,
  `aws elbv2 describe-listeners …`, `aws ecr describe-images …`,
  `aws acm describe-certificate …`, `aws iam get-role …` — READ-ONLY snapshots
  of cloud truth. Prefer these over console screenshots for records.
- `terraform state list | output` — READ-ONLY. Never hand-edit state files.

## 5. Deployment & updates

- `git push origin main` — STATE-CHANGING (triggers CI + Release + ArgoCD
  sync chain). Push code fixes first, tag pins after green runs.
- `kubectl apply -f argocd/apps/staging.yaml|project.yaml` — STATE-CHANGING.
  Required for ArgoCD's *own* manifests (it never self-applies). Verify via
  application status, not the `configured` echo alone.
- `terraform apply -var-file=staging.tfvars` — STATE-CHANGING (provisions/
  replaces; node replacement drains ~8+ min). Never while asleep (revives
  nodes). Approve the plan's destroy list explicitly.
- `aws eks update-nodegroup-config … --scaling-config …` — STATE-CHANGING.
  The sanctioned scaler (desired is API-managed). Confirm via describe + nodes.
- `helm -n <ns> list -a` — READ-ONLY. `failed` releases block Terraform;
  `uninstall` + re-apply is the recovery (Ch. 10 ESO episode).

## 6. Logs & debugging

- `kubectl -n <ns> logs deploy/<name> [--previous] [--tail=N]` — READ-ONLY.
  `--previous` for crashed containers; name pods explicitly with replicas >1.
- `kubectl -n <ns> describe pod <name>` — READ-ONLY. Events section diagnoses
  scheduling/secrets/image failures (our three canonical pod errors).
- `kubectl run -n <ns> psql-drill --rm -i … --image=postgres:16-alpine -- psql
  …` — READ-ONLY (with SELECTs). Password via Secrets Manager into env, never
  typed; pod self-deletes. Doubles as restore verification (Ch. 11).
- `kubectl -n <ns> exec deploy/<be> -- php artisan tinker --execute='…counts…'`
  — READ-ONLY with count queries. Writes via tinker/seed are STATE-CHANGING —
  restrict to demo seeding with explicit env, never defaults.
- Actions logs: UI per step; `Re-run failed jobs` after infra fixes. Decode
  OIDC claims procedure lives in Ch. 10 (temporary debug step, removed after).

## 7. Networking & connectivity

- `curl -s -o /dev/null -w "%{http_code}\n" https://<host>/api/v1/health|/` —
  READ-ONLY. 200/200 healthy; 301 HTTP→HTTPS expected; 422 from bad-creds
  login proves API+DB path (used by `wake.sh`); 503/504 = nothing behind ALB.
- Direct DNS queries (`CNAME`/`A`/`CAA` via 1.1.1.1) — READ-ONLY. Local
  resolvers mislead; authoritative answers don't.
- Chain check (openssl/python against system roots + expiry printout) —
  READ-ONLY. Calendar-check 30 days pre-expiry regardless of auto-renew.
- `kubectl get ingress -o yaml` + `describe-listeners` + controller logs —
  READ-ONLY triangulation for any Ingress misbehavior (Ch. 10 pattern).

## 8. Security inspection

- `aws iam get-role … --query AssumeRolePolicyDocument`, `…-policy …`,
  `get-open-id-connect-provider` (thumbprints!) — READ-ONLY. Compare against
  `iam-github-oidc.tf`/`eso-irsa.tf` on any auth failure.
- `kubectl -n <ns> describe sa <name> | grep role-arn` — READ-ONLY. Missing
  annotation = IRSA silently absent (pods must restart after annotating).
- `kubectl get clustersecretstore … -o jsonpath Ready` — READ-ONLY.
  `False/InvalidProviderConfig` = IAM side, not chart side.
- `composer audit`, `npm audit --audit-level=high` (latter not in CI — run
  manually), Trivy tables in Actions, SARIF in Security tab — READ-ONLY
  gates with teeth; triage per Ch. 10 (don't lower thresholds to ship).
- Gitleaks runs in CI; local pre-push secret hunt: `git log -p | grep` for
  accident patterns is crude but honest — better: never stage `.env` (Ch. 7).

## 9. Performance & resources

- `kubectl describe node | grep -A6 Allocated` — READ-ONLY. Requests vs
  capacity; plus ENI pod caps (11 on t3.small) — the binding constraint here.
- `kubectl -n <ns> get hpa` — READ-ONLY. Exists but blind without
  metrics-server (prioritized backlog).
- `aws cloudwatch get-metric-statistics …` / Console metrics — READ-ONLY.
  RDS CPU/storage, ALB latency/5xx baselines before any sizing claim.
- `terraform plan` cost-blind spot: it shows resources, never dollars — pair
  every sizing change with the Ch. 11 cost table.

## 10. Rollback & recovery

- App rollback: `git revert` tag-pin commit → push → ArgoCD redeploys older
  immutable image (migrate Job re-runs `migrate --force`: safe for additive
  migrations; destructive schema changes need manual SQL — Ch. 10).
- DB: snapshot → restore-to-new-instance → verify counts → repoint `DB_HOST`
  (Ch. 11 + `backup-restore.md`). PITR variant documented, same verify rule.
- State: S3-versioned; workspace corruption → fresh clone + `init -reconfigure`.
  `state rm` (used once for the OIDC provider transition) orphans nothing only
  when the resource must survive unmanaged — understand before repeating.
- Power: `ops/sleep.sh` / `ops/wake.sh` (Ch. 11). Wake is the recovery path
  for any "everything is down after idle" scare — run wake before debugging.

## 11. Cost inspection

- `aws ce get-cost-and-usage … --group-by Type=DIMENSION,Key=SERVICE` —
  READ-ONLY (Billing API lives in us-east-1 even for ap-south-1 spend).
  Monthly-by-service is the 30-second review habit.
- `aws ecr describe-images …`, `describe-volumes --filters Name=status,
  Values=available`, `describe-addresses` (unattached EIPs bill!), `describe-
  snapshots --owner-ids self`, stopped instances with disks — READ-ONLY
  orphan hunts. Findings to date: old micros terminated, quarantine tags
  deleted, no idle EIPs, no stray snapshots except the drill artifact.
- Budgets/alarms console: verify the billing alarm threshold matches the
  current run-rate after every sizing change (ours outgrew $20 on day one).

## 12. Cleanup & teardown

- ECR tag hygiene: `batch-delete-image` specific tags only; never touch the
  pinned live tag; lifecycle keep-20 handles the rest (READ-ONLY list first).
- Drill instance: `delete-db-instance --skip-final-snapshot` — DESTRUCTIVE to
  the *disposable* (verify identifier twice; production deletes need a final
  snapshot — staging config skips it by design).
- Full teardown (DESTRUCTIVE, Ch. 11 ordering): ArgoCD apps → Helm releases →
  `terraform destroy` (snapshot RDS manually first — no final snapshot on
  staging) → confirm ALB/nodes/RDS gone → keep S3 state + ECR + snapshots +
  secrets until explicitly released. Verify billing drops to ~$0 over 48h.
