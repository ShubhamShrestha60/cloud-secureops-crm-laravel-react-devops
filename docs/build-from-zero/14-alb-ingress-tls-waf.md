# 14 — ALB, TLS, DNS, and WAF

**Goal:** expose the app on HTTPS with a valid certificate, route `/api` and
`/`, and put AWS WAF in front of the ALB.

**Time:** 20–45 minutes (DNS/ACM validation dominates).
**Cost:** ALB hourly + LCU charges, ACM public certificates are free, WAF has a
per-ACL and per-request cost. **Safety:** `STATE-CHANGING`.

---

## 14.1 How the pieces connect

```text
Client
  → Route 53 (CNAME/alias) → ALB DNS
  → AWS WAF (REGIONAL ACL, associated to ALB)
  → ALB listener :443 (ACM cert) or :80 (redirect)
  → Ingress paths: /api → backend Service, / → frontend Service
  → Pods on container port 8080
```

The ALB is **not** created by Terraform. The AWS Load Balancer Controller creates
it from the Ingress object. Terraform only looks it up by tag to attach WAF.

---

## 14.2 ALB controller prerequisites

The controller needs:

- IRSA role with the AWS load balancer policy.
- The controller installed as an EKS add-on (`aws_eks_addon.aws_lb_controller`).
- Subnet tags for discovery:
  - public subnets: `kubernetes.io/role/elb = 1`
  - private subnets: `kubernetes.io/role/internal-elb = 1`
  - both: `kubernetes.io/cluster/<cluster-name> = shared`

Without subnet tags the controller logs `couldn't auto-discover subnets` and no
ALB appears.

Verify:

```bash
kubectl -n kube-system get deployment aws-load-balancer-controller
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=50
```

---

## 14.3 Request an ACM certificate (manual)

The original project created the certificate outside Terraform. The commands,
parameterized:

```bash
CERT_ARN=$(aws acm request-certificate \
  --domain-name staging.example.com \
  --validation-method DNS \
  --region ap-south-1 \
  --query CertificateArn --output text)

aws acm describe-certificate \
  --certificate-arn "$CERT_ARN" \
  --region ap-south-1 \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord'
```

Create the returned `_acme-challenge` (or `_<token>`) CNAME in Route 53, then
wait:

```bash
aws acm wait certificate-validated \
  --certificate-arn "$CERT_ARN" --region ap-south-1
```

Notes:

- ACM must be in the same region as the ALB for a regional certificate.
- The certificate must be `ISSUED`, not merely requested.
- Do not commit the certificate ARN; keep it in `values-staging.yaml` as an
  environment value.

---

## 14.4 DNS

Point the hostname at the ALB. Either:

- Route 53 alias record to the ALB, or
- CNAME to the ALB DNS name (not valid at the zone apex).

```bash
aws elbv2 describe-load-balancers --region ap-south-1 \
  --query 'LoadBalancers[].DNSName' --output text

dig +short staging.example.com
```

Propagation can take minutes. Check from outside your network before debugging
Kubernetes.

---

## 14.5 Ingress annotations that matter

From `values-staging.yaml`:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
alb.ingress.kubernetes.io/certificate-arn: <ACM_CERT_ARN>
alb.ingress.kubernetes.io/ssl-redirect: "443"
alb.ingress.kubernetes.io/healthcheck-path: /up
alb.ingress.kubernetes.io/success-codes: 200-399
```

Common traps:

- `ssl-redirect` takes the **port string** `"443"`, not `"true"`.
- `target-type: ip` requires the controller to register pod IPs; the Service must
  be `ClusterIP`, which it is.
- Health check path `/up` is Laravel's lightweight endpoint. `/api/v1/health`
  touches more dependencies and is used for pod readiness, not the ALB check.
- If the cert ARN is missing/invalid, the controller may create an HTTP-only ALB
  or fail the HTTPS listener.

After ArgoCD syncs:

```bash
kubectl -n secureops-staging get ingress
kubectl -n secureops-staging describe ingress secureops-staging

aws elbv2 describe-load-balancers --region ap-south-1 \
  --query 'LoadBalancers[].[LoadBalancerName,State.Code,DNSName]' --output table

aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN> --region ap-south-1 \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
```

All targets should be `healthy`. `unhealthy` usually means the ALB cannot reach
port 8080, the readiness path fails, or a security group blocks traffic.

---

## 14.6 WAF

`infra/terraform/waf.tf` creates a REGIONAL Web ACL:

- Default action: allow.
- AWS managed **CommonRuleSet**.
- AWS managed **KnownBadInputsRuleSet**.
- Rate-based rule: `limit = 3000`, aggregate key `IP`.
- Associated to the ALB found by tag `elbv2.k8s.aws/cluster = <cluster>`.

Apply:

```bash
cd infra/terraform
terraform apply -var-file=staging.tfvars -auto-approve
```

Verify:

```bash
aws wafv2 list-web-acls --scope REGIONAL --region ap-south-1 --output table
aws wafv2 get-web-acl-for-resource \
  --resource-arn <ALB_ARN> --region ap-south-1
```

### Accuracy note

The rule is named `login-rate-limit`, but it is a **global per-IP rate limit**,
not scoped to `/api/v1/login`. It protects against volumetric abuse but allows a
distributed brute force to stay under 3000 requests per IP. A true login limiter
belongs at the application layer (Laravel rate limiter) or a WAF rule with a
scope-down statement. Document this honestly.

Also note `override_action { none {} }` means managed rules run in their default
action, including possible false positives on JSON bodies. Check sampled requests
before tightening.

---

## 14.7 End-to-end verification

```bash
curl -sS -o /dev/null -w 'root: %{http_code}\n' https://staging.example.com/
curl -sS -o /dev/null -w 'api health: %{http_code}\n' https://staging.example.com/api/v1/health
curl -sS -I http://staging.example.com/ | grep -i '^location:'
curl -sS -I https://staging.example.com/ | grep -i 'strict-transport\|content-security'
```

Expected: `200` for both, HTTP redirects to HTTPS, security headers present.

Check the certificate chain:

```bash
openssl s_client -connect staging.example.com:443 -servername staging.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

---

## 14.8 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| No ALB created | missing subnet tags or controller | tag subnets, check controller logs |
| `ssl-redirect` error | boolean value | use `"443"` |
| TLS handshake fails | cert not ISSUED or wrong region | validate ACM in ALB region |
| Targets unhealthy | SG/port/health path | check target health reason |
| 503 from ALB | no healthy targets | fix readiness/probes |
| 502 from ALB | backend crash / wrong port | check pod logs and Service targetPort |
| DNS points nowhere | CNAME stale or not propagated | compare with ALB DNS, use `dig` |
| WAF blocks legitimate JSON | managed rule false positive | inspect sampled requests; scope rules |
| WAF association fails | no ALB yet / tag mismatch | create app Ingress first, then apply |

**Next:** first deploy and verification in `15-first-deploy-and-verification.md`.
