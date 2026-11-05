# 07 — RDS Postgres and Secrets

**Goal:** create the private Postgres database, store its credentials in AWS
Secrets Manager, and verify that Kubernetes can read them through External
Secrets Operator (ESO).

**Time:** 5–10 minutes plus RDS creation. **Cost:** `db.t3.micro` + 20 GiB
storage, roughly $15/month. **Safety:** `STATE-CHANGING`; deleting the DB is
`DESTRUCTIVE` and staging has no final snapshot.

---

## 7.1 What Terraform creates

`infra/terraform/rds.tf`:

- `random_password.db` — 24 characters, no special characters.
- Security group `secureops-staging-rds` allowing TCP 5432 **only** from the
  EKS node security group.
- DB subnet group using both private subnets.
- `aws_db_instance`:
  - Postgres 16, `db.t3.micro`, 20 GiB `gp3`, encrypted
  - not publicly accessible
  - `multi_az = false` for staging
  - 1-day backup retention for staging (7 days in prod)
  - `deletion_protection = false`, `skip_final_snapshot = true` for staging
- `aws_secretsmanager_secret.db` named `secureops/staging/database`.
- `aws_secretsmanager_secret_version.db` containing JSON:
  `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`.

The generated password lives in Terraform state and in Secrets Manager. Treat
both as sensitive. Never print the secret in CI logs or commit it.

---

## 7.2 Apply and verify RDS

```bash
cd infra/terraform
terraform apply \
  -var-file=staging.tfvars \
  -var "github_repo=<GITHUB_OWNER>/<GITHUB_REPO>" \
  -auto-approve
```

Verify status and network:

```bash
aws rds describe-db-instances \
  --db-instance-identifier secureops-staging \
  --region ap-south-1 \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address,PubliclyAccessible,MultiAZ,StorageEncrypted]' \
  --output table
```

Expected: `available`, a private endpoint, `False` for public, `False` for
MultiAZ (staging), `True` for encryption.

Check the security group source:

```bash
aws ec2 describe-security-groups --region ap-south-1 \
  --filters Name=group-name,Values=secureops-staging-rds \
  --query 'SecurityGroups[].IpPermissions' --output json
```

The only ingress source should be the EKS node SG, not a CIDR.

---

## 7.3 Verify the generated database secret without printing it

```bash
aws secretsmanager describe-secret \
  --secret-id secureops/staging/database \
  --region ap-south-1 \
  --query '[Name,ARN]'

aws secretsmanager get-secret-value \
  --secret-id secureops/staging/database \
  --region ap-south-1 \
  --query SecretString --output text \
  | jq -r 'keys[]'
```

Expected keys: `DB_DATABASE`, `DB_HOST`, `DB_PASSWORD`, `DB_PORT`, `DB_USERNAME`.
Do not run `cat` on the value in a shared terminal or paste it into chat.

---

## 7.4 Create the application secret (manual)

Terraform creates the database secret. The application secret is created by
hand so it is not stored in Terraform state:

```bash
APP_KEY="base64:$(openssl rand -base64 32)"

aws secretsmanager create-secret \
  --name secureops/staging/app \
  --region ap-south-1 \
  --secret-string "{
    \"APP_KEY\": \"${APP_KEY}\",
    \"APP_URL\": \"https://staging.example.com\",
    \"FRONTEND_URL\": \"https://staging.example.com\",
    \"CORS_ALLOWED_ORIGINS\": \"https://staging.example.com\"
  }"
```

Replace the hostname with your real one. `APP_KEY` must be a Laravel-valid key:
`base64:` plus 32 random bytes encoded in base64.

> The original deployment created this secret with localhost URLs and did not
> update it after the ALB existed. Same-origin requests still worked, but
> generated URLs/emails were wrong. Create it with the final URL from the start,
> or rotate it after Chapter 14 and restart pods.

Update an existing secret later:

```bash
aws secretsmanager put-secret-value \
  --secret-id secureops/staging/app \
  --region ap-south-1 \
  --secret-string '<json>'
```

ESO refreshes every minute, but pods read env vars at boot. Restart them after
rotation:

```bash
kubectl -n secureops-staging rollout restart deploy/secureops-secureops-backend
kubectl -n secureops-staging rollout restart deploy/secureops-secureops-frontend
```

---

## 7.5 Wire ESO

`argocd/clustersecretstore.yaml` defines a cluster-wide store:

```yaml
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-south-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

The ServiceAccount is annotated by Terraform (`addons.tf`) with the ESO IRSA
role. That role can read only `secureops/staging/*` and `secureops/prod/*`.

The Helm chart creates an `ExternalSecret` with sync-wave `-10`:

```yaml
spec:
  refreshInterval: 1m
  secretStoreRef: { name: aws-secretsmanager, kind: ClusterSecretStore }
  target: { name: secureops-secret, creationPolicy: Owner }
  dataFrom:
    - extract: { key: secureops/staging/app }
    - extract: { key: secureops/staging/database }
```

Both secrets are extracted into one Kubernetes Secret. The migration Job
(sync-wave `-5`) and the Deployments wait for it.

Apply the store once ArgoCD is running:

```bash
kubectl apply -f argocd/clustersecretstore.yaml
```

Verify:

```bash
kubectl get clustersecretstore aws-secretsmanager \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'

kubectl -n secureops-staging get externalsecret
kubectl -n secureops-staging get secret secureops-secret
```

Expected: `True`, `SecretSynced`, and the Secret exists.

---

## 7.6 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `CreateContainerConfigError` | Secret not created yet | check ExternalSecret status and ESO logs |
| `InvalidProviderConfig` | ESO IRSA missing/wrong | verify SA annotation and role trust |
| `AccessDenied` on GetSecretValue | secret path outside role resource | confirm `secureops/staging/*` path |
| Migrate Job waits forever | secret wave/order broken | ensure ESO is running and wave `-10` |
| Pods 500 but DB is available | wrong DB_HOST or stale secret after rotation | restart pods; verify secret keys |
| RDS connection timeout | SG source not node SG, or wrong VPC | re-check security group and DB subnet group |

**Next:** create the registries and keyless CI auth in
`08-ecr-and-github-oidc.md`.
