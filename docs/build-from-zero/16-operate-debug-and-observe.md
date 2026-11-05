# 16 — Operate, Debug, and Observe

**Goal:** a repeatable day-2 workflow: inspect, diagnose, change safely, and roll
back without guessing.

**Time:** ongoing. **Cost:** running stack. **Safety:** reads are `READ-ONLY`;
`rollout restart/undo`, `delete pod`, and `scale` are `STATE-CHANGING`; deleting
PVCs/namespaces is `DESTRUCTIVE`.

---

## 16.1 The first five commands for any incident

```bash
kubectl -n secureops-staging get pods -o wide
kubectl -n secureops-staging get events --sort-by=.lastTimestamp | tail -30
kubectl -n argocd get application secureops-staging
kubectl -n secureops-staging logs deploy/secureops-staging-backend --tail=100
kubectl -n secureops-staging describe pod <pod>
```

Order matters: events often name the real cause (`FailedMount`,
`CreateContainerConfigError`, `Unhealthy`) before logs show anything.

---

## 16.2 Where the logs are

| Layer | Command |
|---|---|
| Backend app | `kubectl -n secureops-staging logs deploy/secureops-staging-backend` |
| Frontend nginx | `kubectl -n secureops-staging logs deploy/secureops-staging-frontend` |
| Migration Job | `kubectl -n secureops-staging logs job/<name>` |
| External Secrets | `kubectl -n external-secrets logs deploy/external-secrets` |
| ALB controller | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| ArgoCD | `kubectl -n argocd logs deploy/argocd-application-controller` |
| Node/system | `kubectl -n kube-system logs <pod>` |

Laravel is configured with `LOG_CHANNEL=stderr`, so container logs are the app
log. There is **no centralized logging**: logs disappear when pods are deleted.
For production, ship stdout to CloudWatch/Loki/ELK.

Useful live views:

```bash
kubectl -n secureops-staging logs -f deploy/secureops-staging-backend
kubectl -n secureops-staging logs -f deploy/secureops-staging-frontend
```

---

## 16.3 Triage flow

1. **Is it the edge?**
   ```bash
   curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' https://<host>/
   ```
   5xx from ALB with no pod logs → check target health/listener.
2. **Is it the pods?**
   `get pods` → `describe pod` → `logs`.
3. **Is it config/secrets?**
   `get externalsecret` → describe → check AWS Secrets Manager.
4. **Is it the database?**
   `php artisan migrate:status`, RDS status, security groups, credentials.
5. **Is it the deployment?**
   ArgoCD sync status, Git diff, image tag in values.
6. **Is it capacity?**
   node count, pending pods, resource requests/limits.

Do not restart things first. Restarting destroys evidence.

---

## 16.4 Change safely

All desired state lives in Git. The safe loop:

```bash
git pull --rebase
# edit values/chart/code
helm template secureops charts/secureops -f charts/secureops/values-staging.yaml >/tmp/r.yaml
# commit, push
kubectl -n argocd get application secureops-staging -w
```

Because ArgoCD has `selfHeal: true`, a manual `kubectl edit` is reverted. If you
must debug live, understand that the change is temporary and record it, then put
the real fix in Git.

---

## 16.5 Rollback

Preferred: revert the Git commit that changed the image tag or chart.

```bash
git revert <sha>
git push
```

ArgoCD then reconciles back. This preserves auditability.

Emergency-only Kubernetes rollback:

```bash
kubectl -n secureops-staging rollout history deploy/secureops-staging-backend
kubectl -n secureops-staging rollout undo deploy/secureops-staging-backend
```

Caveat: ArgoCD `selfHeal` may revert the manual rollback on the next sync. For a
real incident, disable auto-sync or revert in Git. The same applies to
`rollout restart` and `scale`.

---

## 16.6 Resource pressure and scaling

```bash
kubectl -n secureops-staging get pods
kubectl -n secureops-staging describe node <node> | grep -A5 'Allocated resources'
kubectl top nodes
kubectl top pods -n secureops-staging
```

If `kubectl top` fails, metrics-server is missing. Without it:

- HPA cannot compute CPU and will not scale.
- You cannot see actual usage, only requests/limits.

Fix by installing metrics-server, then verify `kubectl top` and
`kubectl get hpa` show values.

Node-level capacity is managed by the EKS managed node group. Scaling pods past
node capacity leaves pods `Pending` until the node group grows (if configured).

---

## 16.7 Secrets and rotation

The app reads secrets from a Kubernetes Secret populated by External Secrets from
AWS Secrets Manager. To rotate:

1. Update the value in Secrets Manager.
2. Wait for ESO refresh (default `1m`) or force a sync.
3. Restart the Deployment so processes pick up new env values:

```bash
kubectl -n secureops-staging rollout restart deploy/secureops-staging-backend
```

Env vars are read at process start; updating the Secret alone does not change a
running process.

For `APP_KEY` rotation, Laravel encrypted data must be re-encrypted; do not rotate
casually.

---

## 16.8 Backups and database health

Automated RDS backups are configured in Terraform (`backup_retention_period`,
`backup_window`). Check:

```bash
aws rds describe-db-instances --db-instance-identifier secureops-staging \
  --region ap-south-1 \
  --query 'DBInstances[0].[DBInstanceStatus,BackupRetentionPeriod,LatestRestorableTime]'
```

A stopped RDS instance cannot be backed up/restored at an arbitrary point; resume
it first. See Chapter 17 for the tested backup/restore drill.

---

## 16.9 What is not observable here

Be explicit in interviews and docs:

- No metrics-server → no working CPU autoscaling and no `kubectl top`.
- No Prometheus/Grafana → no dashboards or historical metrics.
- No centralized logs/tracing → no cross-pod request trace.
- SNS alarms exist, but `alert_email` was empty, so **no one was notified**.
- No uptime/synthetic monitoring.
- No cost anomaly detection.

These are backlog items, not claims. A senior answer names the gap and the next
step.

---

## 16.10 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Manual fix disappears | ArgoCD selfHeal | change Git |
| Logs vanish after pod delete | no log aggregation | ship logs to CloudWatch/Loki |
| `kubectl top` unavailable | metrics-server missing | install it |
| HPA `<unknown>` | no metrics | metrics-server |
| Pending pods | insufficient node capacity | scale node group / requests |
| OOMKilled | memory limit too low | raise limit, investigate leak |
| Secret updated, app unchanged | env read at startup | rollout restart |
| Alarm never fired email | SNS subscription absent | set `alert_email`, confirm |

**Next:** sleep, wake, backup, and restore drills in
`17-sleep-wake-backup-restore.md`.
