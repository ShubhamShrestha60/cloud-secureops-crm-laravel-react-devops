# 20 — Full Rebuild Checklist

**Goal:** one page to rebuild from nothing, in order, with a verification gate at
each step.

**Time:** ~90–150 minutes end to end. **Cost:** running stack; tear down when
done. **Safety:** mostly `STATE-CHANGING`; chapter 18 is `DESTRUCTIVE`.

Commands assume the repository root and `ap-south-1`. Replace placeholders:
`<ACCOUNT_ID>`, `<GITHUB_OWNER>`, `<GITHUB_REPO>`, `<DOMAIN>`, `<ACM_CERT_ARN>`.

---

## Phase 0 — prerequisites

- [ ] AWS account, IAM admin (or enough permissions), MFA enabled.
- [ ] Budget + anomaly alerts created (Chapter 19).
- [ ] Route 53 hosted zone for `<DOMAIN>`.
- [ ] GitHub repo with Actions enabled.
- [ ] AWS CLI v2, Terraform >= 1.5, kubectl, Helm, Docker, jq installed.
- [ ] Clock correct: `date -u`; if skewed, `sudo chronyc -a makestep`.
- [ ] `aws sts get-caller-identity` returns the expected account.

Verify:

```bash
aws sts get-caller-identity
terraform version
kubectl version --client
helm version
docker version --format '{{.Server.Version}}'
```

---

## Phase 1 — remote state and network

- [ ] Create the state bucket and lock table (Chapter 04).
- [ ] `terraform init` succeeds against S3 backend.
- [ ] Apply VPC, subnets, IGW, NAT, route tables, security groups.
- [ ] Subnets tagged for ALB discovery.

```bash
cd infra/terraform
terraform init
terraform apply -var-file=staging.tfvars -target=module.vpc -auto-approve
terraform output
```

Gate: VPC and subnets exist; public/private route tables correct; NAT available.

---

## Phase 2 — EKS and RDS

- [ ] EKS cluster + managed node group (2 AZs, 3× `t3.small`).
- [ ] OIDC provider + IRSA roles.
- [ ] EKS add-ons: VPC CNI, CoreDNS, kube-proxy, EBS CSI, AWS LB Controller.
- [ ] RDS PostgreSQL 16, `db.t3.micro`, not public.
- [ ] Secrets Manager DB secret + `secureops/staging/app`.

```bash
terraform apply -var-file=staging.tfvars \
  -var "github_repo=<GITHUB_OWNER>/<GITHUB_REPO>" -auto-approve

aws eks update-kubeconfig --name secureops-staging --region ap-south-1
kubectl get nodes
aws rds describe-db-instances --db-instance-identifier secureops-staging \
  --region ap-south-1 --query 'DBInstances[0].DBInstanceStatus'
```

Gate: nodes `Ready`; RDS `available`; secrets exist.

---

## Phase 3 — ECR, OIDC, images

- [ ] ECR repositories created (immutable, scan-on-push, lifecycle).
- [ ] GitHub OIDC provider + release role.
- [ ] GitHub Actions Variables set (`AWS_ROLE_TO_ASSUME`, region, repo names).
- [ ] Release workflow pushes `sha-*` images; Trivy gate passes.

```bash
aws ecr describe-repositories --region ap-south-1 --output table
terraform output -raw github_release_role_arn
```

Gate: both images exist with a `sha-*` tag and a completed scan.

---

## Phase 4 — ArgoCD and secrets

- [ ] ArgoCD installed (prefer a pinned version).
- [ ] Repo credentials configured if the repo is private.
- [ ] `AppProject` + `Application` applied.
- [ ] ClusterSecretStore + ExternalSecret templates present.
- [ ] ExternalSecret reports `SecretSynced`.

```bash
./argocd/bootstrap.sh
kubectl -n argocd get applications
kubectl -n secureops-staging get externalsecret
```

If the upstream CRD apply fails with `metadata.annotations: Too long`, re-apply
with `--server-side`.

---

## Phase 5 — values and first deploy

- [ ] `values-staging.yaml` has real ECR URLs and `sha-*` tags.
- [ ] Ingress host, TLS, and cert ARN set.
- [ ] `helm lint` and `helm template` pass.
- [ ] Sync completes; migration Job succeeds.
- [ ] Pods `Ready`; seed admin; smoke test.

```bash
helm lint charts/secureops -f charts/secureops/values-staging.yaml
helm template secureops charts/secureops -f charts/secureops/values-staging.yaml >/tmp/r.yaml
kubectl -n argocd patch application secureops-staging --type merge -p '{"operation":{"sync":{}}}'
kubectl -n secureops-staging get pods
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/api/v1/health
```

Gate: HTTPS 200, login works, a contact persists.

---

## Phase 6 — edge

- [ ] ACM certificate `ISSUED` in the ALB region.
- [ ] Route 53 record points at the ALB.
- [ ] ALB targets healthy.
- [ ] WAF associated.
- [ ] HTTP redirects to HTTPS.

```bash
aws acm list-certificates --region ap-south-1 --query 'CertificateSummaryList[].Status'
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --region ap-south-1
aws wafv2 get-web-acl-for-resource --resource-arn <ALB_ARN> --region ap-south-1
```

---

## Phase 7 — operational readiness

- [ ] SNS `alert_email` set and subscription confirmed.
- [ ] Budget alerts verified.
- [ ] Metrics-server installed (or the HPA gap accepted and documented).
- [ ] Log retention set.
- [ ] Backup/restore drill repeated.
- [ ] Sleep/wake tested.

```bash
kubectl top pods -n secureops-staging
kubectl get hpa -n secureops-staging
./ops/sleep.sh --dry-run
```

---

## Phase 8 — shut down

- [ ] Delete ArgoCD Application.
- [ ] Delete Ingress / ALB.
- [ ] `terraform destroy`.
- [ ] Sweep ALB/TG, EIP, NAT, EBS, logs, snapshots, ECR.
- [ ] Delete lock table.
- [ ] Delete state bucket last.
- [ ] Re-check Cost Explorer after 24–48 hours.

```bash
cd infra/terraform
terraform destroy -var-file=staging.tfvars -auto-approve
```

Gate: `describe-*` calls return empty lists; no surprise line items next day.

---

## Fast path for a local demo only

If the goal is to show the app, skip AWS entirely:

```bash
docker compose up --build
```

This proves the application and container wiring but **not** EKS, IRSA, ESO,
ALB, ACM, WAF, or GitOps. Do not claim those from a compose run.

---

## Final gate

You are done when all of these are true:

- `https://<DOMAIN>/` returns the SPA.
- `/api/v1/health` returns healthy.
- ArgoCD is `Synced` and pods are `Ready`.
- ExternalSecret is `SecretSynced`.
- A contact persists across a refresh.
- Alerts have a confirmed recipient.
- You can sleep, wake, and destroy without orphans.
- You know which observability features are missing.

If any line is false, fix it before calling the rebuild complete.
