# 04 — AWS Bootstrap and Remote State

**Goal:** create the durable state layer Terraform uses to remember what it
owns. Do this before the first `terraform apply`.

**Time:** 10 minutes. **Cost:** pennies per month (S3 storage + on-demand
DynamoDB reads/writes). **Safety:** bucket/table creation is `STATE-CHANGING`;
deleting them while resources still exist is `DESTRUCTIVE`.

> **Never delete the state bucket before destroying the resources.** The
> original teardown deleted the bucket first, which made Terraform unable to
> manage the remaining ALB. Destroy from state first, then remove the bucket.

---

## 4.1 Why remote state

Terraform state maps real AWS resources to the code. If it lives only on your
laptop, losing the laptop means losing the map. Remote state in S3:

- survives workstation loss,
- can be locked so two applies do not race,
- keeps sensitive resource attributes out of Git (the bucket is private).

The state file still contains sensitive values (including generated DB
passwords). Treat it as a secret.

---

## 4.2 Create the bucket and lock table

Choose a globally unique bucket name. The original used
`secureops-tfstate-<ACCOUNT_ID>`.

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="secureops-tfstate-${ACCOUNT_ID}"
TABLE="secureops-terraform-locks"
REGION="ap-south-1"
```

Create the bucket:

```bash
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
```

Block public access, enable versioning, and enable default encryption:

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

Create the lock table:

```bash
aws dynamodb create-table \
  --table-name "$TABLE" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION"
```

Verify:

```bash
aws s3api get-bucket-versioning --bucket "$BUCKET"
aws s3api get-bucket-encryption --bucket "$BUCKET"
aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" \
  --query 'Table.TableStatus'
```

Expected: `Enabled`, an AES256 rule, and `ACTIVE`.

---

## 4.3 Point Terraform at the backend

Open `infra/terraform/backend.tf`. It should contain:

```hcl
terraform {
  backend "s3" {
    bucket         = "secureops-tfstate-<ACCOUNT_ID>"
    key            = "secureops/eks/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "secureops-terraform-locks"
    encrypt        = true
  }
}
```

Replace the bucket with yours. The `key` is the path inside the bucket; keep it
stable or Terraform will think the stack vanished.

> The `dynamodb_table` argument is deprecated in newer Terraform (S3-native
> lockfiles are preferred). This project still uses it. If your Terraform
> version warns, that is expected; migrate deliberately later, not mid-build.

Initialize:

```bash
cd infra/terraform
terraform init
```

Expected: providers and modules download, backend initialized, lock file
written (`.terraform.lock.hcl`).

If you previously used local state, migrate it:

```bash
terraform init -migrate-state
```

---

## 4.4 Validate before planning

```bash
terraform fmt -check -recursive
terraform validate
```

Expected: no output for `fmt -check` means clean; `validate` prints
`Success! The configuration is valid.`

If `validate` fails, fix the code before creating anything.

---

## 4.5 First plan

Use the staging variables and override the GitHub repo:

```bash
terraform plan \
  -var-file=staging.tfvars \
  -var "github_repo=<GITHUB_OWNER>/<GITHUB_REPO>" \
  -out=tfplan
```

Read the plan:

- `Plan: 60+ to add, 0 to change, 0 to destroy` (exact count changes over time).
- No unexpected replaces of existing resources.
- The EKS version matches `staging.tfvars` (1.32), not the variable default.

Do **not** apply yet if you have not created the budget guardrail. Go back to
Chapter 01 if needed.

---

## 4.6 Common state problems

| Symptom | Cause | Fix |
|---|---|---|
| `Error acquiring the state lock` | previous run interrupted or concurrent apply | verify no apply is running; `terraform force-unlock <LOCK_ID>` only then |
| `state data in S3 does not have the expected content` | DynamoDB digest is stale after manual bucket changes | remove the stale `*-md5` item only after confirming the state file is correct |
| `NoSuchBucket` | bucket deleted or name mismatch | recreate the bucket with the same name, or migrate state deliberately |
| `Error loading state` after deleting bucket | bucket gone | recreate it, restore the state object from backup/versioning if available |
| `dynamodb_table is deprecated` | newer Terraform | expected warning; do not change backends mid-build |

**Next:** create the network in `05-network-vpc-subnets-nat.md`.
