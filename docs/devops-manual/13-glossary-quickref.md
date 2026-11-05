# Appendix — Glossary, risk register, quick reference, sources

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

## Glossary (terms as used in this repo)

- **ALB / Ingress / IngressClass `alb`**: AWS load balancer / the K8s object
  describing L7 routing / the controller binding between them.
- **ArgoCD Application/Project**: desired-state declaration / allowlist scope
  (repos + destination namespaces) constraining it.
- **Desired state / drift / self-heal**: git-declared config / live divergence /
  ArgoCD's automatic reconvergence.
- **ECR immutable tag**: a tag the registry refuses to overwrite — makes
  `sha-xxx` a content promise.
- **ESO / ExternalSecret / ClusterSecretStore**: operator / per-release secret
  declarer / cluster-wide AWS-auth config.
- **HPA / PDB**: CPU-driven replica scaling / minimum-availability guard for
  voluntary disruption.
- **IRSA**: pod-level AWS identity via ServiceAccount annotation + cluster OIDC.
- **OIDC `sub`/`aud`**: JWT subject/audience claims gated by IAM trust policy.
- **Sync-wave**: ArgoCD ordering annotation (`-10` secrets → `-5` migrate → `0`
  workloads). **Helm hook**: same idea for `helm` CLI path.
- **Provenance/SBOM**: build attestations / dependency inventory (dropped here
  where they conflicted with scan-before-push; ECR scan remains).
- **SARIF**: static-analysis interchange format uploaded to GitHub Security tab.
- **CAA / ACM validation CNAME**: DNS records authorizing CAs / proving domain
  control for certificate issuance.
- **PITR**: point-in-time restore from WAL + base backup (documented variant,
  1-day window here).

## Risk & improvement register (live list — update on change)

| # | Risk | Status | Next action |
|---|---|---|---|
| 1 | Single region; single-AZ RDS; 1-day retention | Accepted (cost) | Revisit on funding |
| 2 | No metrics-server → HPA blind | Open, P1 | One-release install |
| 3 | Alarms have no email subscriber | Open, P1 | Set `alert_email` |
| 4 | SM secrets unversioned, no rotation schedule | Open, P2 | Versioning + calendar |
| 5 | Shared demo credentials in chat history | Accepted (showcase-only) | Rotate post-demo phase |
| 6 | ArgoCD `Degraded` cosmetic flag | Accepted w/ evidence | Revisit on symptom |
| 7 | No SAST/DAST/signing/admission policy | Open, P2 | Backlog order Ch. 12 |
| 8 | `npm audit` absent from CI | Open, P2 | Add job |
| 9 | EKS API endpoint public | Accepted (bootstrap convenience) | Restrict on hardening pass |
| 10 | Stopped-RDS 7-day auto-wake vs sleep model | Mitigated (runbook) | Monitor |

## 5-minute quick reference

```bash
export KUBECONFIG=~/.kube/config            # always first on stacked hosts
kubectl -n argocd get applications          # want Synced
kubectl -n secureops-staging get pods       # want 4/4 Running
curl -s -o /dev/null -w "%{http_code}\n" https://staging.shubham-shrestha.com.np/api/v1/health
sh ops/sleep.sh ; sh ops/wake.sh            # power, ~$100 asleep / ~$199 awake
terraform -chdir=infra/terraform plan -var-file=staging.tfvars   # always before apply
```

## Official sources (consult before version bumps)

- AWS: EKS, ALB Controller annotations, RDS backup/restore, WAFv2, IAM OIDC,
  ACM DNS validation, Cost Explorer APIs.
- Kubernetes: Deployments/rolling updates, Services, Ingress, HPA, PDB, Jobs,
  security contexts, scheduling (max-pods/ENI).
- ArgoCD: Applications/Projects, sync-waves, ignoreDifferences, ApplicationSets (not used).
- External Secrets Operator: ClusterSecretStore, ExternalSecret statuses.
- GitHub Actions: OIDC-to-AWS (`configure-aws-credentials`), Buildx, SARIF upload, Dependabot.
- Trivy: image scanning, severity gating, SARIF format. Verify action tags via
  the tags API — deletions upstream caused two incidents here.
- Terraform AWS/EKS/Helm providers + EKS module v20 (note its `ignore_changes`
  on node desired size).
- Laravel 12 (Sanctum, factories/`fake()` helper conditions), Vite + nginx
  non-root patterns.
