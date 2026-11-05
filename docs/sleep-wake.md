# Sleep / Wake runbook — SecureOps showcase env

- Owner: platform (Shubham). Last tested: 2026-10-08 (full supervised sleep→wake, ~8 min wake).
- Sleep: ~5 min → burn **~$100/mo**. Wake: ~15 min → burn **~$199/mo**, link shareable.
- Rule: wake the stack *before* submitting applications or interviews, never during.

## Preconditions (every run)

```bash
export KUBECONFIG=~/.kube/config   # local kubectl defaults to k3s otherwise
date -u                            # must match real UTC; if skewed: sudo chronyc -a makestep
aws sts get-caller-identity --region ap-south-1
```

## Sleep (`sh ops/sleep.sh [--dry-run]`)

1. Pre-flight AWS auth — aborts on clock skew. Never proceed half-authenticated.
2. Nodegroup `desired 0` via AWS API (`min 0/max 4`). **Never `kubectl scale` Deployments** — ArgoCD self-heal owns pod counts and reverts it.
3. `stop-db-instance`. AWS auto-restarts stopped RDS after **7 days** — sleeping longer requires re-running sleep weekly.
4. Confirm: `kubectl get nodes` empty, RDS `stopped`, site URL returns **503/504 with resolving DNS** (ALB alive, no targets = paused, not broken).
5. Log line appended to `~/logs/secureops-power.log`.

## Wake (`sh ops/wake.sh [--dry-run]`)

1. Same pre-flight → `start-db-instance`, wait `available` (15-min timeout).
2. Nodegroup `desired 3` → wait 3 nodes Ready + 4/4 app pods Running (12-min timeout).
3. Proof: HTTPS `/api/v1/health` 200, SPA `/` 200, login-shape POST returns **422** (bad creds rejected = API+DB path proven end to end; no token created).
4. Prints `DONE LIVE`. Only then share the link.

## Verification (Layer 1–3)

```bash
kubectl -n argocd get applications            # Synced (health flag cosmetic, see quirks)
kubectl -n secureops-staging get pods         # 4/4 Running
curl -s -o /dev/null -w "%{http_code}\n" https://staging.shubham-shrestha.com.np/api/v1/health
```

## Guardrails

- No `terraform apply` while asleep (it would revive nodes as a side effect).
- Node desired-count is API-managed by design (upstream EKS module `ignore_changes`); Terraform owns type + min/max only.
- Sleep never touches: ECR images, Secrets Manager, DNS, ACM cert, Terraform state, WAF rules.
- Alarms may flap while asleep (silent — no email configured).

## Known quirks (hit during setup)

- Alma clock drifts when the VM suspends → all AWS signatures fail. Fix with sudo chronyc; NTP discipline recommended.
- `t3.small` fits only as 3 nodes: 11 pods/node ENI limit vs 26 cluster pods (ArgoCD alone is 7).
- ArgoCD `Degraded` flag with zero unhealthy resources is a v3.5.3 display quirk; sync/pods/endpoints are the real signals.
