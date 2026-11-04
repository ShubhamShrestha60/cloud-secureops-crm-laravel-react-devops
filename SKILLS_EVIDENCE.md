# Skills → Evidence

A claim is only useful if a reviewer can find the artifact. Each row points to a
file or command output that supports the claim, followed by the honest limit.

## Infrastructure as Code

**Claim:** can structure Terraform for a real multi-service AWS environment.

**Evidence:** `infra/terraform/` — separated `network.tf`, `eks.tf`, `addons.tf`,
`rds.tf`, `ecr.tf`, `iam-github-oidc.tf`, `eso-irsa.tf`, `alarms.tf`, `waf.tf`,
plus variables, tfvars, outputs, and an S3/DynamoDB backend.

**Limit:** single environment; no Terragrunt/workspaces; provider versions are
pinned but not digest-locked.

---

## AWS networking

**Claim:** can build a VPC with public/private subnets, NAT egress, and subnet
tags required by the AWS Load Balancer Controller.

**Evidence:** `infra/terraform/network.tf`; the subnet tag requirements are
explained in `docs/build-from-zero/05-network-vpc-subnets-nat.md`.

**Limit:** one NAT gateway; staging uses 2 AZs. This is a cost trade-off, not a
full HA design.

---

## EKS

**Claim:** can provision EKS, a managed node group, OIDC/IRSA, and the standard
add-ons.

**Evidence:** `infra/terraform/eks.tf`, `addons.tf`, `eso-irsa.tf`; the
node-count/autoscaler interaction is documented in
`docs/build-from-zero/06-eks-cluster-nodes-addons.md`.

**Limit:** no Karpenter, no cluster autoscaler tuning, no multi-cluster design.

---

## Keyless CI authentication

**Claim:** can replace static AWS keys with GitHub OIDC and scope trust by repo
and ref.

**Evidence:** `infra/terraform/iam-github-oidc.tf`,
`.github/workflows/release.yml`; failure modes in `docs/reference/errors.md`.

**Limit:** trust pattern covers GitHub's numeric-ID subject formats; it was not
tested against every GitHub plan/claim variant.

---

## Container supply chain

**Claim:** can build non-root images and enforce a scan gate before push.

**Evidence:** `backend/Dockerfile`, `frontend/Dockerfile`,
`.github/workflows/release.yml`, `docs/build-from-zero/09-docker-images.md` and
`11-release-pipeline.md`.

**Limit:** images are tag-pinned, not digest-pinned. There is no SBOM, signing,
or provenance attestation because those require push-during-build, which would
break scan-before-push.

---

## Kubernetes packaging

**Claim:** can write a Helm chart with probes, security contexts, HPA, PDB,
migration ordering, and Ingress.

**Evidence:** `charts/secureops/`; explanation in
`docs/build-from-zero/12-helm-chart.md`.

**Limit:** HPA was not effective because metrics-server was absent. The chart was
correct; the cluster observability was incomplete.

---

## GitOps

**Claim:** can operate ArgoCD with automated sync, prune, self-heal, sync waves,
and drift handling.

**Evidence:** `argocd/project.yaml`, `argocd/apps/staging.yaml`,
`docs/build-from-zero/13-argocd-gitops.md`.

**Limit:** no ArgoCD SSO, no public UI hardening, no image updater; bootstrap uses
upstream `stable` instead of a pinned release.

---

## Secrets management

**Claim:** can deliver Secrets Manager values to pods without committing them.

**Evidence:** `infra/terraform/rds.tf`, `eso-irsa.tf`,
`argocd/clustersecretstore.yaml`, `charts/secureops/templates/secrets.yaml`,
`docs/build-from-zero/07-rds-secrets.md`.

**Limit:** `APP_KEY` rotation procedure (re-encryption) was not exercised.

---

## Edge and security

**Claim:** can wire DNS, ACM TLS, ALB, and WAF, and explain the constraints.

**Evidence:** `charts/secureops/templates/ingress.yaml`,
`infra/terraform/waf.tf`, `docs/build-from-zero/14-alb-ingress-tls-waf.md`.

**Limit:** the WAF rate rule is global per IP, not login-scoped. ACM was created
manually, not by Terraform.

---

## Operations and incident response

**Claim:** can debug a live Kubernetes delivery path and write a runbook.

**Evidence:** `docs/build-from-zero/16-operate-debug-and-observe.md`,
`docs/reference/errors.md`, the incident section in
`docs/PROJECT_JOURNAL.md`.

**Limit:** no on-call rotation, SLOs, or production incident process. This was a
lab environment.

---

## Backup and restore

**Claim:** can prove a database backup is recoverable, not just scheduled.

**Evidence:** `docs/build-from-zero/17-sleep-wake-backup-restore.md`; observed
counts matched after restore.

**Limit:** point-in-time recovery to an arbitrary second was not tested. Restore
was at lab data size.

---

## Cost control and teardown

**Claim:** can identify fixed-cost resources, sleep a stack, and delete it
without orphans.

**Evidence:** `ops/sleep.sh`, `ops/wake.sh`,
`docs/build-from-zero/18-teardown-zero-cost.md`,
`docs/build-from-zero/19-cost-guardrails.md`.

**Limit:** the sleep script had a 10-minute drain timeout that produced a false
fatal even when scale-down succeeded. The budget/anomaly commands were documented
but not proven with a live alert in this run.

---

## Documentation

**Claim:** can turn an as-built system into a reproducible manual.

**Evidence:** `docs/DEVOPS_ENGINEERING_MANUAL.md`, the 21 chapters in
`docs/build-from-zero/`, `docs/reference/`, and the sanitized appendix.

**Limit:** prose is long by design; the reader must still run the verification
gates rather than trusting the text.

---

## Remediation backlog (what I would do next)

1. Install metrics-server; verify HPA scaling with a load test.
2. Add Prometheus/Grafana or CloudWatch Container Insights; ship logs centrally.
3. Set `alert_email`, confirm the SNS subscription, and test an alarm end to end.
4. Scope the WAF rate rule to `/api/v1/login`; add an application login limiter.
5. Pin ArgoCD to a release tag; add SSO and restrict the UI.
6. Migrate Terraform locking from `dynamodb_table` to `use_lockfile` and upgrade
   providers.
7. Add digest pinning and an SBOM/signing step without breaking scan-before-push
   (for example, scan, push by digest, then attest).
8. Add a canary or blue/green path for the backend; test a bad migration.
9. Add PITR restore to a specific timestamp and document RTO/RPO.
10. Add branch protection and required checks so CI is a real gate.
