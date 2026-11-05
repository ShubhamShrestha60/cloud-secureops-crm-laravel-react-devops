# Part VII — Observability and production operations

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

## 8.1 What exists (and what pointedly does not)

Present: three-level probes (liveness `/up`, readiness `/api/v1/health`,
ALB healthcheck `/up` via `traffic-port`, success `200-399`), 3 CloudWatch
alarms (RDS CPU, RDS free storage, ALB 5xx → SNS topic, no email subscriber),
WAF sampled requests, Kubernetes events, app/supervisor/nginx logs via
`kubectl logs`, and the `ops/wake.sh` Layer-3 proof (health + SPA + login-shape
422). Absent: metrics-server (`kubectl top` fails), Prometheus/Grafana, log
aggregation/retention policy, tracing, uptime checks from outside AWS,
on-call routing. Say it plainly in interviews: *alarms cover resource exhaustion
and total 5xx storms; everything else is diagnosed from probes + logs.*

## 8.2 The health ladder in practice (Ch. 3.15 applied)

Debug in ladder order and stop at the first broken rung:

1. `kubectl get pods` — `Running`? If `Pending`: scheduler events (pods caps,
   Ch. 10). If `CrashLoopBackOff`: previous container's logs.
2. `kubectl logs deploy/…` — did nginx/php-fpm stay up? (Our greatest hits:
   upstream-DNS emerg, `/var/lib/nginx` permission, `/tmp/nginx.pid`
   read-only.)
3. `curl` the endpoint — 200? 301→HTTPS? 422-shape (proves API+DB)? 503/504
   (nothing behind ALB — check nodes/RDS awake)?
4. Behavior — login returns token? Data correct? Seed state as expected?

Each rung's tool answers one question; jumping rungs (e.g., re-pushing images
when DNS is the fault) is the classic time-waster Ch. 10 exists to prevent.

## 8.3 Logs: where they live, how to read them

- App/supervisor: `kubectl -n secureops-staging logs deploy/<name> [--previous]`
  (`--previous` for crashed containers; multi-pod? name the pod).
- ALB access logs: NOT enabled (stated gap — enable to S3 when traffic
  forensics matter; costs storage, gains per-request truth).
- LB Controller / ESO / ArgoCD: same `kubectl logs` in `kube-system`,
  `external-secrets`, `argocd` namespaces. Controller reconcile errors are the
  fastest path for any Ingress misbehavior (our `ssl-redirect` parse error
  surfaced there in seconds).
- GitHub Actions: per-step logs; re-run failed jobs (never whole workflows
  blindly). Runner clocks/versions appear in run headers — read them when
  actions misbehave (Ch. 10).
- Retention reality: pod logs die with pods; SNS/alarms have no history UI
  beyond CloudWatch; treat chat-transcript + commit messages as the incident
  record until aggregation exists.

## 8.4 Alarms: what fires, what it means, what to do

| Alarm | Meaning | First action |
|---|---|---|
| `…-rds-cpu-high` (>80%, 3×5min) | DB under sustained load | `logs` for slow queries; check connections; scale class (needs apply) |
| `…-rds-storage-low` (<5GiB) | Growth or log bloat | Identify growth (largest tables via psql pod); raise `allocated_storage` |
| `…-alb-5xx` (>20/10min) | Targets erroring | Ladder from rung 2: pod logs, then ESO secret freshness, then RDS reachability |

All route to SNS with no subscriber (RECOMMENDATION: set `alert_email`;
confirm the subscription email or notifications silently succeed nowhere).
Add (backlog, Ch. 12): ALB target-healthy-count, pod-restart-rate,
cert-expiry (ACM auto-renews, but monitor the automation), WAF-blocked spike.

## 8.5 Capacity without metrics-server

Cluster math, the only tool available: sum container `requests` vs node
allocatable (`kubectl describe node`), plus the ENI pod cap (11 on t3.small
— the binding constraint that forced 3 nodes, Ch. 12). HPA targets 70% CPU
but cannot *see* CPU without metrics-server — FACT: HPA objects exist and are
`Synced`, but autoscaling is effectively blind until metrics-server is
installed (prioritized backlog item; one Helm release, outsized value).
Until then, capacity changes are manual (`update-nodegroup-config`,
documented API-managed pattern).

## 8.6 Incident method (evidence over guessing)

1. Timestamp + symptom in one sentence (status codes, not adjectives).
2. Ladder (8.2), recording each rung's output.
3. Form ONE hypothesis consistent with ALL outputs; test the cheapest
   disproof first (e.g., DNS query before cert replacement).
4. Remediate minimally; prefer git-tracked fixes over `kubectl` improvisation
   (improvised fixes become tomorrow's drift — the ExternalSecret annotation
   episode is the template: unblock live, codify in git immediately).
5. Verify Layer 1–3 + demo login; append to the relevant runbook with date.
6. If the flag/symptom has no underlying fault after N probes (our Degraded
   saga: six probes, zero faults), time-box, document, move on — declare the
   stopping rule up front so pride doesn't schedule the work.
