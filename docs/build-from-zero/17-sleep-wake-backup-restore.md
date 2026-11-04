# 17 — Sleep, Wake, Backup, and Restore

**Goal:** cut burn to near zero between demos without deleting state, and prove
the database can actually be restored.

**Time:** sleep ~10–20 min; wake ~15–25 min; restore ~15–30 min.
**Cost:** asleep still burns for EKS control plane, ALB/WAF, and storage
(~$100/month observed); awake adds nodes/RDS.
**Safety:** sleep/wake are `STATE-CHANGING`; restore creates a new DB
(`STATE-CHANGING`); deleting snapshots is `DESTRUCTIVE`.

---

## 17.1 What sleep does and does not do

`ops/sleep.sh`:

1. Verifies AWS auth (fails fast on clock skew).
2. Scales the managed node group to `min=0, max=4, desired=0`.
3. Calls `rds stop-db-instance` (tolerates already-stopped).
4. Waits up to 10 minutes for nodes to disappear.
5. Confirms RDS is `stopped`/`stopping`.

It does **not** delete:

- ECR images, Secrets Manager secrets, DNS, ACM certificate.
- Terraform state (S3/DynamoDB).
- The EKS control plane, ALB, WAF, or RDS storage.

Why scale the **node group** instead of the Deployments? ArgoCD owns pod counts
with `selfHeal: true`; scaling Deployments by hand would be reverted. The node
group is invisible to GitOps.

```bash
./ops/sleep.sh --dry-run   # prints intent, changes nothing
./ops/sleep.sh             # real run
```

### Known false failure

The original run scaled the node group correctly but the drain wait ended with
`nodes still present after 10 min` and exited non-zero. This was a **timing/false
fatal**, not a failed scale-down. Check the actual state before rerunning or
panicking:

```bash
aws eks describe-nodegroup --cluster-name secureops-staging \
  --nodegroup-name <ng> --region ap-south-1 \
  --query 'nodegroup.scalingConfig'

aws rds describe-db-instances --db-instance-identifier secureops-staging \
  --region ap-south-1 --query 'DBInstances[0].DBInstanceStatus'
```

The script is idempotent; rerunning is safe.

### RDS 7-day gotcha

AWS automatically restarts a stopped RDS instance after **7 days**. Sleep is not
a permanent cost cap. For long pauses, snapshot and delete the instance (Chapter
18), or accept the restart.

---

## 17.2 Wake

`ops/wake.sh`:

1. Scales the node group back to `min=2, max=4, desired=3`.
2. Starts RDS and waits for `available`.
3. Waits for nodes to be `Ready`.
4. Leaves ArgoCD to reconcile pods.

```bash
./ops/wake.sh
```

Expected timeline: nodes ~5–10 min, RDS ~5–10 min, pods a few minutes after
that. First request may be slow while caches warm.

Verify:

```bash
kubectl get nodes
aws rds describe-db-instances --db-instance-identifier secureops-staging \
  --region ap-south-1 --query 'DBInstances[0].DBInstanceStatus'
kubectl -n secureops-staging get pods
curl -sS -o /dev/null -w '%{http_code}\n' https://<host>/api/v1/health
```

### Wake/when order matters

Bring up **RDS before** relying on pods, and **nodes before** pods can schedule.
The scripts sequence this. If you start RDS while nodes are still at zero, the
migration Job may fail and ArgoCD may retry; check the Job rather than assuming
success.

---

## 17.3 The tested backup/restore drill

Tested 2026-10-12. The point was not "backups exist" but "a restore produces the
same data."

### Step 1 — snapshot

```bash
aws rds create-db-snapshot \
  --db-instance-identifier secureops-staging \
  --db-snapshot-identifier secureops-staging-manual-$(date +%Y%m%d%H%M) \
  --region ap-south-1

aws rds wait db-snapshot-completed \
  --db-snapshot-identifier secureops-staging-manual-<timestamp> \
  --region ap-south-1
```

### Step 2 — record the source counts

```bash
kubectl -n secureops-staging exec deploy/secureops-staging-backend -- \
  php artisan tinker --execute="echo json_encode([
    'users' => App\Models\User::count(),
    'contacts' => App\Models\Contact::count(),
    'logs' => App\Models\ActivityLog::count(),
  ]);"
```

The drill recorded `users=2, contacts=13, logs=13`. Use your own numbers; the
principle is to compare source and restore.

### Step 3 — restore to a new instance

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier secureops-staging-restore-test \
  --db-snapshot-identifier <snapshot-id> \
  --db-instance-class db.t3.micro \
  --db-subnet-group-name <subnet-group> \
  --vpc-security-group-ids <sg-id> \
  --no-publicly-accessible \
  --region ap-south-1
```

**Critical:** specify the subnet group and VPC security group. If you omit them,
RDS may place the instance in the default VPC where the cluster cannot reach it.
Verify:

```bash
aws rds describe-db-instances \
  --db-instance-identifier secureops-staging-restore-test \
  --region ap-south-1 \
  --query 'DBInstances[0].[DBInstanceStatus,DBSubnetGroup.VpcId,VpcSecurityGroups[].VpcSecurityGroupId]'
```

### Step 4 — verify data

Point a temporary client at the restored instance (do **not** change the app):

```bash
PGPASSWORD=<password> psql \
  -h <restored-endpoint> -U secureops -d secureops \
  -c 'select count(*) from users;' \
  -c 'select count(*) from contacts;' \
  -c 'select count(*) from activity_logs;'
```

Compare with Step 2. Then delete the test instance:

```bash
aws rds delete-db-instance \
  --db-instance-identifier secureops-staging-restore-test \
  --skip-final-snapshot \
  --region ap-south-1
```

### What the drill proved

- The snapshot is restorable.
- Network placement must be explicit.
- Counts matched the source at snapshot time.
- Deletion of the test instance is safe and does not touch the source.

### What it did not prove

- Point-in-time recovery to an arbitrary second (not tested).
- Restore of application-encrypted fields after an `APP_KEY` change.
- Restore time at production data sizes.

Say that plainly.

---

## 17.4 Retention settings

Terraform sets `backup_retention_period` (1 day in staging) and a backup window.
Check:

```bash
aws rds describe-db-instances --db-instance-identifier secureops-staging \
  --region ap-south-1 \
  --query 'DBInstances[0].[BackupRetentionPeriod,PreferredBackupWindow,LatestRestorableTime]'
```

One day is a staging trade-off, not a production policy. Production should use
7–35 days, cross-region copies where required, and tested PITR.

---

## 17.5 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `sleep.sh` exits `nodes still present` | 10-min wait too short | verify scale config; rerun |
| RDS refuses stop | already stopped / recent start | tolerate; check status |
| RDS running again after a week | AWS auto-restart | expected; snapshot/delete for long pause |
| Wake pods crash | RDS not ready yet | wait for `available`; check Job |
| Restored DB unreachable | default VPC / wrong SG | pass subnet group + SG explicitly |
| Restore counts differ | snapshot taken before writes | compare timestamps; acceptable if explained |
| App cannot decrypt after restore | different `APP_KEY` | restore the matching key |

**Next:** delete everything cleanly in `18-teardown-zero-cost.md`.
