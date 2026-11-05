# Backup & restore — SecureOps RDS Postgres

- Last drilled: 2026-10-12 (snapshot → temp instance → row-count match → destroy).
- Live data changes; the drill procedure below re-verifies on demand.

## What protects the data

- Automated daily snapshots, 02:00–03:00 UTC window, 1-day retention
  (staging cost choice; prod template uses 7 days + Multi-AZ).
- Storage encrypted at rest (gp3). Manual snapshot `secureops-drill-20261012`
  retained as the drill artifact (billed on actual usage, cents).
- Secrets Manager holds DB creds; ECR images are immutable — the database
  is the only stateful component, hence the only restore target.

## Restore drill (safe: never touches the live instance)

```bash
REGION=ap-south-1
# 1. Fingerprint live data (counts only, no dump leaves the cluster).
kubectl -n secureops-staging exec deploy/secureops-staging-backend -- \
  php artisan tinker --execute='echo "users=".App\Models\User::count().",contacts=".App\Models\Contact::count().PHP_EOL;'

# 2. Manual snapshot of live.
aws rds create-db-snapshot --db-instance-identifier secureops-staging \
  --db-snapshot-identifier secureops-drill-$(date +%Y%m%d) --region $REGION
#    wait: Status available

# 3. Restore to a DISPOSABLE instance. Network flags are REQUIRED:
#    restore defaults to the default VPC (unreachable from EKS) otherwise.
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier secureops-drill-verify \
  --db-snapshot-identifier <snapshot-id> \
  --db-instance-class db.t3.micro \
  --db-subnet-group-name secureops-staging \
  --vpc-security-group-ids <rds-sg-id> \
  --no-multi-az --no-publicly-accessible --region $REGION
#    wait: Status available (~10 min)

# 4. Verify row counts from an ephemeral psql pod (auto-deleted, --rm).
#    Password via Secrets Manager, never pasted.
kubectl -n secureops-staging run psql-drill --rm -i --restart=Never \
  --image=postgres:16-alpine --env="PGPASSWORD=<from-secret>" -- \
  psql -h <drill-endpoint> -U <user> -d <db> -tAc \
  "SELECT 'users='||(SELECT count(*) FROM users)||',contacts='||(SELECT count(*) FROM contacts);"
#    expected: identical to step 1.

# 5. Destroy the disposable instance (keep the snapshot).
aws rds delete-db-instance --db-instance-identifier secureops-drill-verify \
  --skip-final-snapshot --region $REGION
```

## Gotchas recorded 2026-10-12

- Restore without `--db-subnet-group-name`/`--vpc-security-group-ids`
  lands in the default VPC → connection timeouts from EKS pods.
- Real disaster path (live instance lost): same flow, but restore with the
  production identifier + update `secureops/<env>/database` `DB_HOST` in
  Secrets Manager; ESO syncs it to pods within a minute, no redeploy needed.
- PITR uses the same verify/destroy pattern with
  `restore-db-instance-to-point-in-time` instead of step 3.
