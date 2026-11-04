# Resume Bullets

Use these as written or adapt the wording. Every bullet maps to an artifact in
this repository; nothing here depends on the application source.

- Designed and operated a production-shaped AWS platform for a Laravel 12 + React
  application using Terraform (VPC, EKS 1.32, managed node group, RDS PostgreSQL,
  ECR, WAF, CloudWatch alarms) across two availability zones.

- Implemented keyless CI-to-AWS authentication with GitHub Actions OIDC and a
  repository-scoped IAM role, eliminating long-lived AWS access keys.

- Built a scan-before-push release pipeline: images are built locally, scanned
  with Trivy at HIGH/CRITICAL, and only pushed to ECR when the gate passes;
  immutable `sha-<commit>` tags make every deployment byte-identifiable.

- Packaged workloads in a Helm chart with health probes, non-root containers,
  resource requests/limits, HPA, PodDisruptionBudget, an ordered migration Job,
  and ALB Ingress routing.

- Implemented pull-based GitOps with ArgoCD (auto-sync, prune, self-heal) and sync
  waves so ExternalSecrets and database migrations complete before application
  pods roll.

- Integrated AWS Secrets Manager with External Secrets Operator and IRSA, keeping
  database and application secrets out of Git and container images.

- Configured the edge path end to end: Route 53, ACM TLS, ALB target groups,
  HTTP-to-HTTPS redirect, WAFv2 managed rules, and a per-IP rate limit.

- Diagnosed and fixed real delivery failures including an EKS version/AMI
  mismatch, an nginx startup failure caused by upstream DNS resolution, Trivy
  gate failures from unfixed base-image CVEs, and ArgoCD CRD apply limits.

- Performed a database restore drill: snapshot → disposable RDS instance →
  row-count comparison (`users=2`, `contacts=13`, `logs=13`) → cleanup, proving
  the backup was recoverable and documenting the subnet-group/security-group
  requirement.

- Reduced idle spend with node-group scale-to-zero and RDS stop scripts, then
  executed a full teardown including orphaned ALB/listener/target-group cleanup
  and an account-wide sweep for NAT, EIP, EBS, log-group, and snapshot leftovers.

- Authored a 21-chapter rebuild manual plus command, file, error, and environment
  references, turning an as-built environment into a reproducible engineering
  record.

## Short version (three bullets)

- Built a Terraform + EKS + RDS platform with OIDC-based GitHub Actions,
  scan-before-push ECR releases, Helm, and ArgoCD GitOps for a Laravel/React app.
- Implemented External Secrets/IRSA, ALB + ACM + WAF, non-root containers,
  health probes, HPA/PDB, and ordered migration Jobs.
- Proved recoverability with an RDS restore drill and documented the full
  build, operation, cost-control, and teardown lifecycle.
