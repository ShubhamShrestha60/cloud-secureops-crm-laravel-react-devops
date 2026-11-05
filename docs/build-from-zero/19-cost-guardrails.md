# 19 — Cost Guardrails

**Goal:** make the bill predictable and stop a lab project from becoming a
four-hundred-dollar lesson.

**Time:** 20 minutes to set up. **Cost:** Budgets and anomaly detection are
free; they do not cap spending by themselves. **Safety:** guardrails are
`STATE-CHANGING`.

---

## 19.1 What actually costs money

For this architecture in `ap-south-1`:

| Resource | Billing model | Lab-scale reality |
|---|---|---|
| EKS control plane | hourly per cluster | the largest fixed cost; charges even with 0 nodes |
| EC2 worker nodes | per second, per instance type | 3× `t3.small` while awake |
| RDS PostgreSQL | hourly + storage | `db.t3.micro`, 20 GB gp3 |
| NAT Gateway | hourly + per GB processed | one NAT; easy to forget |
| ALB | hourly + LCU | survives cluster deletion if orphaned |
| WAF | per ACL + per million requests | small but non-zero |
| ECR | storage per GB | small; old images add up |
| CloudWatch Logs | ingestion + storage | grows silently |
| EBS | per GB-month | leftover volumes after node deletion |
| Elastic IP | hourly when **not** attached | orphaned EIPs cost money |
| Snapshots | per GB-month | manual snapshots persist after DB deletion |
| Data transfer | per GB out | small for a demo |

The surprise is rarely one big line. It is the **sum of always-on pieces**:
control plane + NAT + ALB + WAF + RDS storage. That combination kept burning
roughly **$100/month even while "asleep."**

---

## 19.2 Why this section exists

A lab stack can accumulate cost from always-on components even when it looks idle: the EKS control plane, NAT gateway, ALB, WAF, and RDS storage bill regardless of traffic. The risk is not one expensive resource; it is the sum of fixed charges plus a late alert. The guardrails below turn that into an early warning and a repeatable teardown.

## 19.3 Guardrail 1 — a budget with real alerts

Create a monthly cost budget and alert at 50/80/100% of a number you can afford
(for example $25 for a lab):

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > /tmp/budget.json <<'JSON'
{
  "BudgetName": "secureops-lab-monthly",
  "BudgetLimit": { "Amount": "25", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
JSON

aws budgets create-budget \
  --account-id "$ACCOUNT_ID" \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers '[
    {
      "Notification": {
        "NotificationType": "ACTUAL",
        "ComparisonOperator": "GREATER_THAN",
        "Threshold": 80,
        "ThresholdType": "PERCENTAGE"
      },
      "Subscribers": [
        { "SubscriptionType": "EMAIL", "Address": "you@example.com" }
      ]
    }
  ]'
```

Repeat for 50% and 100%, and add a `FORECASTED` notification at 100%. A budget
alarm is notification-only; it does not stop resources.

Verify:

```bash
aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query 'Budgets[].BudgetName'
```

---

## 19.4 Guardrail 2 — cost anomaly detection

```bash
aws ce create-anomaly-monitor \
  --anomaly-monitor '{
    "MonitorName": "secureops-lab",
    "MonitorType": "DIMENSIONAL",
    "MonitorDimension": "SERVICE"
  }'

aws ce create-anomaly-subscription \
  --anomaly-subscription '{
    "SubscriptionName": "secureops-lab-email",
    "MonitorArnList": ["<MONITOR_ARN>"],
    "Subscribers": [{"Address": "you@example.com", "Type": "EMAIL"}],
    "Frequency": "DAILY"
  }'
```

Use `aws ce get-anomaly-monitors` to fetch the ARN. This catches unexpected
spikes (for example a forgotten NAT or an orphaned ALB) within a day.

---

## 19.5 Guardrail 3 — tag everything

Terraform tags resources with `Project`, `Environment`, and `ManagedBy`. Use
them in Cost Explorer and in cleanup:

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=secureops \
  --region ap-south-1 \
  --query 'ResourceTagMappingList[].ResourceARN' --output table
```

Tag-based cleanup is safer than deleting by name guesswork. Ensure the NAT, ALB,
and EBS volumes carry tags too; controller-created ALBs inherit some tags from
the Ingress annotations.

---

## 19.6 Guardrail 4 — default to asleep or deleted

- Between demos: run `ops/sleep.sh`. Accept that ~$100/month remains.
- For a week or more: snapshot RDS, then `terraform destroy`. Rebuild from this
  manual when needed.
- Never leave the stack running "just in case." An idle lab is the most
  expensive state per unit of value.

Add a calendar reminder to re-check the stack after any demo. The original
incident happened because nobody looked.

---

## 19.7 Guardrail 5 — right-size and cap

- One NAT gateway, not one per AZ.
- `t3.small` nodes; 2 AZs in staging (`staging.tfvars`), not 3.
- `db.t3.micro`, 20 GB gp3, 1-day backups in staging.
- ECR lifecycle: keep 20 images.
- CloudWatch log retention: set a finite retention (for example 14 days) instead
  of "never expire."
- Avoid data transfer between AZs where possible.

These are staging choices. Production needs different trade-offs; say so.

---

## 19.8 Guardrail 6 — a teardown checklist

Keep `18-teardown-zero-cost.md` next to the budget. The last mile is where money
leaks:

- ALB and target groups.
- NAT gateway and EIPs.
- Unattached EBS volumes.
- Manual RDS snapshots.
- CloudWatch log groups.
- ECR images.
- DynamoDB lock table.
- S3 state bucket (last).

---

## 19.9 Verify spend

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '7 days ago' +%F),End=$(date -u +%F) \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE
```

Cost Explorer lags by hours; a same-day teardown can still show charges into the
next day. Check again after 24–48 hours before concluding something is still
running.

---

## 19.10 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Budget alert never arrives | wrong email / no SNS confirm / notifications not configured | verify subscriber and budget notifications |
| Bill keeps rising after destroy | orphan ALB/NAT/EIP/snapshot/log group | run the orphan sweep |
| Anomaly monitor silent | monitor/subscription not created or ARN wrong | list monitors, recreate subscription |
| Cost Explorer shows $0 | data delay or wrong date range | wait, widen range |
| NAT cost high with no traffic | NAT hourly is fixed | delete NAT when deleting stack |
| EIP charge | unattached Elastic IP | release it |
| RDS still charging | stopped DB still bills storage; auto-restarts after 7 days | snapshot then delete for long pauses | and delete for long pauses |

**Next:** the final rebuild checklist in `20-rebuild-checklist.md`.
