# 18 — Teardown to Zero Cost

**Goal:** remove every billable resource in the right order, with no orphans and
no surprise charges.

**Time:** 20–40 minutes (EKS/RDS deletion is slow).
**Cost:** this is how you stop the bill. Until it completes, resources keep
charging. **Safety:** `DESTRUCTIVE`. There is no undo.

---

## 18.1 Order matters

Correct order:

1. Remove the ArgoCD Application (stop reconciliation).
2. Delete the Ingress / let the ALB controller remove the ALB.
3. `terraform destroy`.
4. Sweep for orphans (ALB/TG, EIP, NAT, EBS, logs, snapshots).
5. Remove the Terraform lock table.
6. Remove the state bucket **last** (only after state is no longer needed).

Why this order:

- If you delete the cluster first, the AWS Load Balancer Controller disappears
  and the ALB it created can be orphaned.
- If you delete the state bucket before `destroy`, Terraform cannot read state
  and cannot delete the remaining resources cleanly.
- `terraform destroy` needs the DynamoDB lock table and S3 backend intact.

---

## 18.2 Step 1 — stop GitOps reconciliation

```bash
kubectl -n argocd get applications
kubectl -n argocd delete application secureops-staging --cascade=foreground
```

Or remove the Application manifest from Git and let ArgoCD prune it. Confirm the
Application is gone before touching infrastructure.

If the UI is unreachable because the cluster is already partly down, skip this
and expect ArgoCD objects to vanish with the cluster.

---

## 18.3 Step 2 — remove the ALB before the cluster

Preferred: delete the Ingress and wait for the controller to delete the ALB.

```bash
kubectl -n secureops-staging delete ingress secureops-staging
```

Then confirm:

```bash
aws elbv2 describe-load-balancers --region ap-south-1 \
  --query 'LoadBalancers[].[LoadBalancerName,State.Code]' --output table
```

If the cluster is already gone and the ALB remains, delete it by hand:

```bash
# listener first (the ALB may refuse to delete while listeners/rule actions exist)
aws elbv2 describe-listeners --load-balancer-arn <ALB_ARN> --region ap-south-1
aws elbv2 delete-listener --listener-arn <LISTENER_ARN> --region ap-south-1
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN> --region ap-south-1

# target groups are independent of the LB
aws elbv2 describe-target-groups --region ap-south-1 \
  --query 'TargetGroups[].[TargetGroupName,TargetGroupArn]' --output table
aws elbv2 delete-target-group --target-group-arn <TG_ARN> --region ap-south-1
```

This is exactly what happened in the original teardown: the ALB and both target
groups survived cluster deletion and were deleted manually.

---

## 18.4 Step 3 — Terraform destroy

```bash
cd infra/terraform
terraform init
terraform destroy -var-file=staging.tfvars -auto-approve
```

Expected deletion time: EKS node group and control plane 10–20 minutes, RDS a
few minutes, EIP/NAT/log groups fast.

If it fails:

| Error | Cause | Fix |
|---|---|---|
| `Error acquiring the state lock` | stale lock from an interrupted run | inspect lock ID; `terraform force-unlock <ID>` only if no run is active |
| `NoSuchBucket` | state bucket deleted manually | restore the bucket or state before destroying; see 18.7 |
| `DependencyViolation` on SG/VPC | leftover ENIs/ALB | delete ALB/TG/ENIs, retry |
| `InvalidParameterValue` deleting log group | already gone | remove from state or ignore |
| `BucketNotEmpty` on ECR | images remain | `force_delete = true` or empty repo first |

After a partial failure, run `terraform plan -destroy -var-file=staging.tfvars`
and fix the specific blocker. Do not delete the state bucket to "make it work."

---

## 18.5 Step 4 — orphan sweep

These resources are often missed because they are not in Terraform or survive a
partial destroy.

```bash
REGION=ap-south-1

aws eks list-clusters --region $REGION
aws rds describe-db-instances --region $REGION \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]' --output table
aws ec2 describe-instances --region $REGION \
  --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' --output table
aws ec2 describe-nat-gateways --region $REGION \
  --filter Name=state,Values=available,pending \
  --query 'NatGateways[].[NatGatewayId,State]' --output table
aws ec2 describe-addresses --region $REGION \
  --query 'Addresses[].[AllocationId,AssociationId,PublicIp]' --output table
aws ec2 describe-volumes --region $REGION \
  --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table
aws elbv2 describe-load-balancers --region $REGION \
  --query 'LoadBalancers[].[LoadBalancerName,State.Code]' --output table
aws elbv2 describe-target-groups --region $REGION \
  --query 'TargetGroups[].[TargetGroupName,TargetGroupArn]' --output table
aws logs describe-log-groups --region $REGION \
  --query 'logGroups[].logGroupName' --output table
aws rds describe-db-snapshots --region $REGION \
  --snapshot-type manual --query 'DBSnapshots[].[DBSnapshotIdentifier,Status]' --output table
aws wafv2 list-web-acls --scope REGIONAL --region $REGION --output table
aws cloudwatch describe-alarms --region $REGION \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
aws sns list-topics --region $REGION
```

Delete only what you created. Snapshots are billable; retention is a decision,
not an automatic delete.

Also check ECR:

```bash
aws ecr describe-repositories --region $REGION \
  --query 'repositories[].repositoryName' --output table
```

If a repository still has images and must go, empty it or rely on
`force_delete`.

### What the original teardown found

- EKS, RDS, EC2 nodes, NAT, EIPs, EBS, and log groups were gone.
- The ALB, its listener, and two target groups remained and were deleted
  manually.
- No leftover NAT/EIP/EBS/log groups were found after the sweep.
- The S3 state bucket had been deleted manually, which complicated Terraform
  destroy.

---

## 18.6 Step 5 — DynamoDB lock table

After Terraform no longer needs it:

```bash
aws dynamodb describe-table --table-name secureops-terraform-locks \
  --region ap-south-1 --query 'Table.TableStatus'

aws dynamodb delete-table --table-name secureops-terraform-locks \
  --region ap-south-1
```

If a stale digest/lock entry blocks a later operation, inspect it first:

```bash
aws dynamodb scan --table-name secureops-terraform-locks --region ap-south-1
```

Delete a specific stale item only after confirming no `terraform` process is
running.

---

## 18.7 Step 6 — state bucket (last)

Only after `destroy` completes and you no longer need history. The bucket has
versioning; empty all versions first:

```bash
aws s3api list-object-versions --bucket <state-bucket> \
  --query 'Versions[].{Key:Key,VersionId:VersionId}' --output text

# delete every version and delete marker (script or console is safer for many objects)
aws s3 rm s3://<state-bucket> --recursive
aws s3api delete-bucket --bucket <state-bucket> --region ap-south-1
```

**Do not do this early.** If the bucket is already gone while resources remain,
Terraform cannot see state. Options:

1. Restore the bucket from a backup or S3 versioning (if recoverable).
2. Recreate the bucket with the same name and restore the `terraform.tfstate`
   object from your local backup / another copy.
3. As a last resort, delete remaining resources manually and accept that
   Terraform state no longer matches (document it).

Deleting state does not delete AWS resources. It only removes your map to them.

---

## 18.8 Final verification

```bash
aws eks list-clusters --region ap-south-1
aws rds describe-db-instances --region ap-south-1 \
  --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-nat-gateways --region ap-south-1 \
  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws ec2 describe-addresses --region ap-south-1 --query 'Addresses[].PublicIp'
aws elbv2 describe-load-balancers --region ap-south-1 \
  --query 'LoadBalancers[].LoadBalancerName'
```

Expected: empty lists. Then check **Billing → Cost Explorer** the next day; some
charges lag by hours. Also check **Billing → Cost anomaly detection** if enabled.

---

## 18.9 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| ALB survives cluster deletion | controller gone before LB cleanup | delete listener/LB/TG manually |
| `terraform destroy` lock error | stale DynamoDB lock | confirm no active run, then force-unlock |
| `NoSuchBucket` | state bucket deleted | restore state before destroying |
| VPC delete `DependencyViolation` | leftover ENI/SG/ALB | find and delete dependencies |
| New charges after teardown | snapshots, EIPs, log groups, ECR | run the orphan sweep |
| EKS still listed | deletion still in progress | wait; check node groups first |
| RDS won't delete | deletion protection | disable protection, retry |
| Final snapshot created | `skip_final_snapshot=false` | expected; delete snapshot or keep intentionally |

**Next:** the cost guardrails that should have prevented the surprise in
`19-cost-guardrails.md`.
