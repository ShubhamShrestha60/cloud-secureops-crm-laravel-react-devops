# Part VI — Networking and security

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

## 7.1 DNS (Cloudflare-owned, AWS-consuming)

- Apex + app DNS live in Cloudflare (NS: `*.ns.cloudflare.com`; apex A =
  Cloudflare IPs; Vercel serves the apex site — untouched by design).
- `staging.shubham-shrestha.com.np` → CNAME → ALB hostname (**DNS-only**/grey:
  orange proxy would front Cloudflare's cert and hide ACM validation).
- `_…​.staging` CNAME → `….acm-validations.aws` proves domain control to ACM;
  **never delete it** (renewal re-checks). Verify (READ-ONLY): direct DNS
  query for `CNAME`/`A`/`CAA` records (procedure in Ch. 9) — local resolvers
  may lie; query `1.1.1.1`/`8.8.8.8` explicitly.
- CAA is checked upward from the FQDN and fails **closed**. This repo's saga:
  malformed `0 issue "0 issue \"amazon.com\""` (Cloudflare's Tag dropdown uses
  plain English — "Only allow specific hostnames" = `issue`; value field takes
  bare `amazon.com`), then `CAA_ERROR` → fixed records → `ISSUED` in minutes.
  Keep `amazon.com` + existing issuers; each ACM request mints fresh validation
  values while CAA persists.

## 7.2 Connectivity and load balancing

Public path: client → ALB (`internet-facing`, 2 AZ subnets) → pod IPs
(`target-type: ip`, no kube-proxy hop). Private: nodes/RDS in private subnets
via one NAT; RDS SG allows :5432 solely from the node SG. EKS API endpoint is
public (bootstrap convenience) — lock down post-setup in stricter postures.
Inspect (READ-ONLY): `kubectl get ingress -o yaml` (hostname, annotations),
`aws elbv2 describe-listeners` (expect 80/HTTP + 443/HTTPS with our cert ARN),
`aws ec2 describe-security-groups` (prove the :5432 source). What checks
*can't* prove: SG rules prove intent, not traffic — confirm with endpoint
curls + controller logs, never config alone.

## 7.3 TLS end to end

ACM cert `…/<CERT_ID>…` (region-pinned to `ap-south-1`), DNS-validated,
auto-renewing while the CNAME lives. Ingress: `listen-ports` 80+443,
`certificate-arn`, `ssl-redirect: "443"` (**string port** — `"true"` fails
reconcile with a parse error, Ch. 10), `tls.hosts` + host rules. ALB
terminates; cluster-internal is HTTP (documented trade-off: mTLS/service mesh
deferred, Ch. 12). Verify: `curl` 200s + 301, plus a chain check against
system roots with expiry date (procedure in Ch. 9). Renewal watch: calendar
reminder 30 days pre-expiry even though ACM auto-renews — automation you don't
monitor is hope.

## 7.4 Firewalls: SGs + WAF

- SGs: RDS closed except node-origin Postgres; nodes' SG managed by the EKS
  module; pods share node networking (no NetworkPolicies in this chart —
  stated gap; namespace isolation is by Service/DNS, not policy).
- WAFv2 (`waf.tf`): Regional ACL on the ALB — CommonRuleSet + KnownBadInputs
  (managed blocking), IP rate-limit 3000/5min guarding `/login` brute force,
  default ALLOW, sampled requests for tuning. Verify association + test a
  benign login (200) after any rule change; canary rule changes in Count mode
  first (RECOMMENDATION — currently all rules block directly).

## 7.5 IAM least privilege (map)

| Principal | May do | May NOT do | Defined in |
|---|---|---|---|
| Human bootstrap user | Everything (temporary) | Should be scoped down post-setup | Console (outside repo) |
| `…-github-release` | ECR push+pull on 2 repos, `GetAuthorizationToken` | Cluster, RDS, SM, any mutation | `iam-github-oidc.tf` |
| `…-eso` (IRSA) | SM read on `secureops/{staging,prod}/*` | Write, other paths | `eso-irsa.tf` |
| `…-lb-controller` (IRSA) | ALB/LB resources via managed policy | — (AWS-managed policy breadth accepted, noted) | `addons.tf` |
| `…-ebs-csi` (IRSA) | Volume attach/mount | — | `eks.tf` |
| Pods (default SA) | Nothing cloud-side | Assumes nothing (no annotation) | Implicit — verify periodically |

Role assumption paths: GHA→STS (JWT `sub`/`aud` gated), pods→STS (IRSA JWT
bound to SA). Rotate posture: OIDC needs no rotation (short-lived by design);
break-glass IAM user keys must have rotation + alarm (VERIFY in console).

## 7.6 Secrets lifecycle

Sources: `/database` (Terraform random) + `/app` (hand-created `APP_KEY`,
URLs). Flow: SM → ClusterSecretStore → ExternalSecret (refresh `1m`) → K8s
Secret → env. Rules enforced by this repo: ARNs in git, values never;
`.gitignore` covers `.env/*.tfstate/*.pem`; Gitleaks gates PRs; `kubectl
exec … env` and `describe pod` LEAK secrets into logs/shell — prefer
`get secret -o jsonpath` to files with tight perms, or the Secrets Manager
console. Rotation: update SM → ESO syncs ≤1 min → restart pods (env is
boot-time; document the restart!). Missing: versioning/restore drills for SM,
per-secret rotation schedule, `secrets.create=true` demo path must never reach
any real env (values guard it; CI does not — RECOMMENDATION: add a CI check).

## 7.7 Vulnerabilities and supply chain (confirmed findings)

- Images: Trivy HIGH/CRITICAL gate pre-push (Ch. 6) + ECR scan-on-push
  backstop + SARIF in Security tab. Historical highs fixed: guzzle, symfony,
  commonmark minors; Laravel 11→12 major (unfixable-on-11 CRLF); `libexpat`/
  `pcre2` via `apk upgrade`; composer `platform.php=8.3` lock discipline.
- Actions supply chain: every third-party action pinned; Dependabot bumps
  weekly. The `setup-trivy` deletion incident is why.
- Base images float (`php:8.3-fpm-alpine`, `nginx:stable-alpine`) — rebuilds
  move them; immutability downstream + lockfiles are the compensating
  controls. Digest-pinning bases is the documented next step (Ch. 12).
- Frontend `npm audit` is NOT in CI (Trivy sees OS+some lib vulns; npm
  audit sees JS advisories) — RECOMMENDATION: add `npm audit --audit-level=high`.
- INVESTIGATE (not claimed): no SAST/DAST, no image signing (cosign), no
  admission policy (Kyverno) — absence noted, not implied.

## 7.8 Boundaries and exposed surfaces (blunt list)

Public: ALB 80/443 (WAF'd), Cloudflare DNS. Semi-public: EKS API endpoint
(authenticated, AWS IAM). Private: RDS, nodes, ECR (IAM-gated), Secrets
Manager. Human-held: GitHub PATs (push + ArgoCD repo read), AWS bootstrap
keys, `admin@…` demo creds (intentionally public for the showcase — staging
only, never a prod pattern), ArgoCD initial admin secret (rotate/disable per
Ch. 12 SSO plan). Confirm each boundary with the Ch. 9 inspection commands;
anything you cannot verify stays in the risk register (Ch. 13), not in prose
assurances.
