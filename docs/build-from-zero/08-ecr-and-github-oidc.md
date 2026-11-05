# 08 — ECR and GitHub Actions OIDC

**Goal:** create private image repositories and let GitHub Actions push to them
without storing long-lived AWS keys.

**Time:** 10 minutes. **Cost:** ECR storage is cheap (pennies per GB/month);
data transfer is small for this project. **Safety:** `STATE-CHANGING`.

---

## 8.1 ECR repositories

`infra/terraform/ecr.tf` creates two repositories:

- `secureops-staging-backend`
- `secureops-staging-frontend`

Settings:

- **Immutable tags** — a tag can never be overwritten. This is what makes
  `sha-<commit>` a content promise.
- **Scan on push** — ECR scans every pushed image as a backstop.
- **AES256 encryption**.
- **Lifecycle policy** — keep the last 20 images.
- `force_delete = true` for staging (so Terraform can delete a non-empty repo).

Get the URLs:

```bash
cd infra/terraform
terraform output -raw ecr_backend_url
terraform output -raw ecr_frontend_url
```

Expected form:

```
<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/secureops-staging-backend
<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/secureops-staging-frontend
```

Verify:

```bash
aws ecr describe-repositories --region ap-south-1 \
  --query 'repositories[].[repositoryName,imageTagMutability]' --output table

aws ecr get-lifecycle-policy \
  --repository-name secureops-staging-backend \
  --region ap-south-1
```

---

## 8.2 Why OIDC instead of access keys

A static key in GitHub Secrets is a long-lived credential that works until
someone rotates it. OIDC replaces it with a short-lived token:

1. The workflow requests a signed JWT from GitHub.
2. AWS STS validates the token against the GitHub OIDC provider.
3. STS issues temporary credentials for the release role.
4. Nothing long-lived is stored in GitHub.

The trust policy must restrict **which repository** and **which branch/tag** can
assume the role. Broad trust (`repo:*`) is a security bug.

---

## 8.3 What Terraform creates

`infra/terraform/iam-github-oidc.tf`:

- The GitHub OIDC provider (or a data source if it already exists in the
  account).
- Role `secureops-staging-github-release`.
- Trust: `aud = sts.amazonaws.com` and `sub` matching
  `repo:<owner>@*/<repo>@*:*`.
- Permissions: ECR auth token, push/pull on the two repositories only.

The numeric-ID wildcard is deliberate. Modern GitHub subject claims look like:

```
repo:owner@12345678/repo@87654321:ref:refs/heads/main
```

The older format had no IDs. The pattern covers both, while still pinning the
owner and repo names.

---

## 8.4 Apply and copy outputs

```bash
terraform apply \
  -var-file=staging.tfvars \
  -var "github_repo=<GITHUB_OWNER>/<GITHUB_REPO>" \
  -auto-approve

terraform output -raw github_release_role_arn
```

Copy these into GitHub → repository → Settings → Secrets and variables →
Actions → **Variables** (not Secrets):

| Variable | Value |
|---|---|
| `AWS_REGION` | `ap-south-1` |
| `AWS_ROLE_TO_ASSUME` | the role ARN from Terraform |
| `ECR_BACKEND_REPOSITORY` | `secureops-staging-backend` |
| `ECR_FRONTEND_REPOSITORY` | `secureops-staging-frontend` |

These are non-secret identifiers. The workflow needs `id-token: write` (already
in `release.yml`) to request the OIDC token.

---

## 8.5 Verify the trust without running a release

```bash
aws iam get-role \
  --role-name secureops-staging-github-release \
  --query 'Role.AssumeRolePolicyDocument' --output json | jq

aws iam list-open-id-connect-providers --output table
```

Check the provider thumbprints:

```bash
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn <PROVIDER_ARN> \
  --query 'ThumbprintList'
```

If the trust is wrong, the workflow fails with:

```
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

That error means the token was valid but the trust policy did not match. It is
not an ECR permission problem yet.

---

## 8.6 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `Not authorized ... AssumeRoleWithWebIdentity` | `sub`/`aud` mismatch or wrong role ARN | decode claims; fix trust pattern |
| `InvalidIdentityToken` / thumbprint error | provider thumbprints stale | refresh thumbprints from the live chain |
| `AccessDenied` on `ecr:InitiateLayerUpload` | role lacks repo permission | check policy resources |
| `RepositoryNotFoundException` | wrong repository name in Variables | compare with `terraform output` |
| `tag already exists` | immutable tag reused | never reuse a tag; push a new commit |
| `GetDownloadUrlForLayer` denied | Trivy pulls the local image via ECR auth | add the permission (already in code) |

**Next:** build the images locally in `09-docker-images.md`.
