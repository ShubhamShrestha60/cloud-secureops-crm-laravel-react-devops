# SecureOps Project Journal

> Private, chronological record of what was built, what broke, how it was fixed,
> and how the environment was finally removed. This journal is intentionally
> more candid than the public portfolio. It is **not** published.

**Project window:** 2026-10-01 → 2026-11-04
**Environment:** AWS `ap-south-1`, EKS `secureops-staging`, single prod-like stage
**Final status:** fully decommissioned (AWS resources deleted, S3 state bucket
and lock table removed manually, ALB and target groups deleted manually)

---

## 1. Timeline from the real Git history

The repository history is the primary source for this timeline. Commit hashes
are abbreviated; run `git log --reverse --date=short --pretty='%ad %h %s'` to
reproduce it.

| Date (2026) | Commit | What happened |
|---|---|---|
| Oct 1 | `3e6ea56` | Initial repository: Laravel API, React SPA, Dockerfiles, Helm chart, Terraform skeleton. |
| Oct 2 | `baa1950` | ESO IRSA role, Helm ordering, staging GitHub OIDC repo wiring. |
| Oct 2 | `cdf9248` | S3 remote state backend; prod EKS template moved to 1.32. |
| Oct 2 | `3e3bbe0` | Staging ECR repos, ExternalSecrets enabled, ArgoCD repo URL + bootstrap paths. |
| Oct 2 | `1a22bdd` | CI: first Trivy action pin attempt (`0.24.0` did not exist). |
| Oct 2 | `1190f66` | CI: corrected Trivy tag to `v0.28.0` (the `v` prefix matters). |
| Oct 2 | `bc3cab6` | CI: bumped to `v0.36.0` because the older tag relied on a deleted `setup-trivy` action. |
| Oct 2 | `dee19c4` | GitHub OIDC thumbprints updated for the Let's Encrypt hierarchy; fixed `AssumeRoleWithWebIdentity` denial. |
| Oct 2 | `e9f05b5` | Temporary workflow step to print OIDC `aud`/`sub`/`iss` claims (removed later). |
| Oct 2 | `3e288fd` | OIDC trust fixed for GitHub's numeric-ID subject format; debug step removed. |
| Oct 2 | `b85d79d` | IAM: allowed `ecr:GetDownloadUrlForLayer` so Trivy could pull the local image. |
| Oct 2 | `34818b0` | Release: push only immutable `sha-*` tags; removed floating `latest`. |
| Oct 2 | `46842ea` | Release: Trivy table output so findings are visible in logs. |
| Oct 2 | `564c93a` | Release: parallel build → scan → push gates; nothing pushed when a scan fails. |
| Oct 2 | `db1afb8` | Dependencies: `apk upgrade` in all stages; Laravel 12.69 to clear HIGH CVEs. |
| Oct 3 | `59679ee` | Composer platform pinned to PHP 8.3 to match the runtime image. |
| Oct 3 | `172b35e` | Pinned the first clean Trivy-gated images (`sha-59679eea1700`). |
| Oct 3 | `bbdad7a` | ArgoCD project allowlist corrected for the renamed private repository. |
| Oct 3 | `7403795` | Runtime fixes: non-root nginx paths, lazy `/api` proxy DNS, ExternalSecret wave `-10`. |
| Oct 3 | `208c84a` | Pinned runtime-fixed images (`sha-7403795fdd87`). |
| Oct 3 | `6292eaf` | Chart: `emptyDir` for `/tmp` so the frontend can run with a read-only root. |
| Oct 4 | `68a5c2f` | HTTPS ingress for `staging.shubham-shrestha.com.np` after ACM issued. |
| Oct 4 | `056f771` | Ingress: `ssl-redirect` takes `"443"`, not `"true"`. |
| Oct 4 | `d493c90` | Factories: switched to the `fake()` helper (Laravel 12 removed the legacy accessor). |
| Oct 5 | `f43692f` | Pinned factory-fixed images (`sha-d493c90819fa`). |
| Oct 5 | `4ea0853` | Moved `fakerphp/faker` to production dependencies (factories run without dev deps). |
| Oct 5 | `60dbd4f` | Pinned faker-prod images (`sha-4ea08538f439`) — the final live image tag. |
| Oct 5 | `4cefcf5` | Ops: ESO `ignoreDifferences`, Dependabot, SARIF upload, removed stale prod Application. |
| Oct 5 | `ceb8364` | Infrastructure: WAF on the ALB, CloudWatch alarms, SNS alert topic. |
| Oct 5 | `6110e6d` | Docs: live URL, single-environment reality, demo login. |
| Oct 6 | `1969e4b` | Nodes changed to 3× `t3.small` (pod-density fit for 26 pods). |
| Oct 8 | `545b849` | Documented that node `desired_size` is API-managed (module `ignore_changes`). |
| Oct 8 | `056ae1b` | Sleep/wake scripts + runbook, tested 2026-10-08. |
| Oct 12 | `7138062` | Backup/restore drill procedure, tested 2026-10-12. |
| Nov 4 | — | Environment decommissioned; AWS resources deleted. |
| Nov 4+ | — | Documentation expanded into Volume 0 + reference indexes; sanitized portfolio prepared. |

---

## 2. What was actually built

### Application

- Laravel 12 API (`backend/`) with Sanctum-style token login, contacts CRUD,
  activity logs, factories/seeders, SQLite tests.
- React SPA (`frontend/`) built with Vite, served by nginx.
- Local-only `docker-compose.yml` for development; never a production path.

### Delivery

- GitHub Actions CI: Pint, PHPUnit, ESLint, Vitest, frontend build, Hadolint,
  Shellcheck, `docker compose config`, Gitleaks.
- Release workflow: parallel backend/frontend builds, local Docker image load,
  Trivy HIGH/CRITICAL gate, SARIF upload, push only the exact scanned bytes,
  immutable `sha-<12>` tags.
- OIDC authentication from GitHub Actions to AWS; no static AWS keys.
- ECR repositories with immutable tags, scan-on-push, lifecycle keep-20.

### Infrastructure (Terraform)

- VPC: 2 AZs, public/private subnets, single NAT for staging, route tables.
- EKS 1.32 with managed node group (3× `t3.small`, min 2, max 4, API-managed desired).
- RDS Postgres 16 `db.t3.micro`, private subnets, 1-day staging backups.
- ECR repos, GitHub OIDC provider/role, ESO IRSA role, EBS CSI IRSA.
- AWS Load Balancer Controller, External Secrets Operator.
- WAFv2 regional ACL on the ALB, CloudWatch alarms, SNS topic.
- Remote state in S3 + DynamoDB lock table.

### Kubernetes / GitOps

- Helm chart with backend/frontend Deployments, Services, PDBs, HPA, migrate
  Job (Helm hook + ArgoCD sync-wave), ALB Ingress, ExternalSecret.
- External Secrets pulls DB credentials and app config from Secrets Manager.
- ArgoCD Application with automated sync + self-heal; project allowlists the
  private repo and the staging/prod namespaces.

### Operations

- Layered health model: `/up`, `/api/v1/health`, SPA `/`, demo login (422 shape).
- Sleep/wake scripts: node group desired → 0 and RDS stop; reverse on wake.
- RDS snapshot/restore drill to a disposable instance with data-count proof.
- Cost model and sleep/wake operating model.

---

## 3. Incidents and fixes (the real debugging history)

These are the failures that shaped the implementation. The public manual turns
them into reusable runbooks; this journal records what actually happened.

1. **Trivy action tag did not exist** — `0.24.0` and then `0.28.0` (without `v`)
   failed. Fixed by using `v0.36.0`; later the older tag's `setup-trivy` action
   was deleted upstream, confirming the risk of floating action dependencies.
2. **OIDC `Not authorized to perform sts:AssumeRoleWithWebIdentity`** — the
   GitHub subject used numeric owner/repo IDs. Temporary claim-printing step
   revealed the exact `sub`; trust policy changed to
   `repo:<owner>@*/<repo>@*:*` and thumbprints were refreshed.
3. **Trivy could not pull the local image** — missing
   `ecr:GetDownloadUrlForLayer` on the release role. Added.
4. **Push-before-scan defect** — the original workflow pushed images before
   scanning. Rebuilt as local build → scan → push, and removed floating
   `latest` because the repository is immutable.
5. **Laravel 11 CVEs unfixable on that major** — upgraded to Laravel 12 and
   `apk upgrade`; Composer platform pinned to PHP 8.3 after a Symfony 8 lock
   resolved against a newer PHP toolbox.
6. **ArgoCD project denied the renamed repo** — `sourceRepos` allowlist updated.
7. **ExternalSecret / migrate job race** — secret not ready when the Job
   started. Added ArgoCD sync-wave `-10` for the secret and Helm hook ordering.
8. **Nginx crashed as non-root** — `/var/lib/nginx` permissions, then
   `/tmp/nginx.pid` under a read-only root. Fixed in the image and chart
   (`emptyDir` for `/tmp`).
9. **Frontend could not resolve `backend` at startup** — nginx resolves upstream
   names at startup. Added a `resolver` + variable-based lazy `/api` proxy.
10. **Ingress `ssl-redirect` parse error** — annotation expects a port string
    (`"443"`), not a boolean (`"true"`).
11. **CAA blocked ACM issuance** — Cloudflare's UI dropdown produced a malformed
    doubled `issue` value. Corrected CAA records; ACM issued within minutes.
12. **Pods stuck `Pending` with `Too many pods`** — `t3.small` ENI density cap
    (11 pods) was the constraint, not CPU/memory. Moved to 3 nodes.
13. **Host clock drift broke AWS CLI** — signatures failed until
    `sudo chronyc -a makestep` corrected ~5 minutes of drift.
14. **Backup restore landed in the default VPC** — restored RDS instance without
    the project subnet group/security group, so it could not reach the app.
    Re-ran with the correct network parameters and verified counts.
15. **ArgoCD bootstrap CRD annotation too long** — `kubectl apply` failed on the
    ApplicationSet CRD. Server-side apply was required for that manifest.

---

## 4. Tests and drills performed

- Local Docker Compose health checks and login-shape verification.
- CI and Release workflows exercised through real failures and fixes.
- Layer 1–3 verification after each deploy: SPA 200, API health 200, bad-login
  422, demo login success, seeded data counts.
- Sleep/wake cycle tested on 2026-10-08: nodes drained to zero, RDS stopped,
  wake restored the site.
- RDS snapshot → disposable instance → exact counts (`users=2`, `contacts=13`,
  `logs=13`) → instance deleted on 2026-10-12.
- Teardown on 2026-11-04: ArgoCD Application deleted, Terraform destroy
  attempted, EKS/RDS/ALB/NAT/EIP/EBS/log groups confirmed gone; the ALB and
  target groups were deleted manually after the Terraform state bucket had
  already been removed.

---

## 5. Cost and teardown lessons

The full financial postmortem is intentionally private. The technical lesson is public and is documented in `docs/build-from-zero/19-cost-guardrails.md` and `18-teardown-zero-cost.md`: always-on components keep billing while a lab looks idle, teardown order matters, and an orphaned ALB or NAT is still a bill.

## 6. Final decommissioning

On 2026-11-04 the decision was made to stop all spend. The user deleted the
resources manually. The sequence observed afterwards:

- `aws eks list-clusters` → empty.
- RDS instance `secureops-staging` absent.
- EC2 instances absent; NAT gateways, EIPs, and EBS volumes absent.
- One ALB `k8s-secureop-…` remained; listener, load balancer, and target groups
  were deleted manually.
- The S3 state bucket had already been deleted manually; Terraform could no
  longer read remote state. The DynamoDB lock table and its stale digest entry
  were removed.
- No CloudWatch log groups remained.
- Local host clock was ~5 minutes slow, so AWS API calls failed until corrected;
  this is why inventory checks must be re-run after fixing NTP.

**Lesson:** deleting the state bucket before `terraform destroy` is dangerous.
It is better to destroy from state first, then delete the state bucket and lock
table. The correct order is documented in Volume 0, Chapter 18.
