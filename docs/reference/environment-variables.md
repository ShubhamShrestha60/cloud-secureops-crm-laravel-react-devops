# Environment Variables and Inputs

Four different layers use the word "environment". Keep them separate.

1. **Terraform variables** — infrastructure inputs.
2. **GitHub Actions variables** — non-secret CI configuration.
3. **Helm values** — Kubernetes workload configuration.
4. **Process env vars** — runtime configuration inside containers and scripts.

Never commit real values for anything marked secret.

---

## 1. Terraform variables (`infra/terraform/variables.tf`)

| Variable | Default | Used by | Notes |
|---|---|---|---|
| `project` | `secureops` | names/tags | change only with a full rename plan |
| `env` | none (required) | names/tags | must be `staging` or `prod` |
| `region` | `ap-south-1` | provider | keep ACM/ALB in the same region |
| `vpc_cidr` | `10.0.0.0/16` | network | plan subnets before changing |
| `az_count` | `3` | network | `staging.tfvars` uses `2` |
| `eks_version` | `1.30` | EKS | `staging.tfvars` uses `1.32` |
| `node_instance_types` | `["t3.medium"]` | node group | staging uses `t3.small` |
| `node_min_size` | `2` | node group | sleep sets 0 |
| `node_max_size` | `4` | node group | cap to control cost |
| `node_desired_size` | `2` | node group | wake uses 3 |
| `db_instance_class` | `db.t3.micro` | RDS | small staging class |
| `db_name` | `secureops` | RDS | database name |
| `db_username` | `secureops` | RDS | password is generated |
| `domain_name` | `""` | (reserved) | empty = no DNS/ACM from Terraform |
| `github_repo` | `""` | OIDC trust | required for release role |
| `alert_email` | `""` | SNS subscription | empty = alarms record, no email |

`staging.tfvars` overrides the defaults. Always pass `-var-file=staging.tfvars`
unless you are deliberately testing defaults.

---

## 2. GitHub Actions configuration

Set under **Settings → Secrets and variables → Actions → Variables**.

| Name | Example | Secret? | Purpose |
|---|---|---|---|
| `AWS_REGION` | `ap-south-1` | no | SDK region |
| `AWS_ROLE_TO_ASSUME` | `arn:aws:iam::<ACCOUNT_ID>:role/secureops-staging-github-release` | no | OIDC role ARN |
| `ECR_BACKEND_REPOSITORY` | `secureops-staging-backend` | no | backend repo name |
| `ECR_FRONTEND_REPOSITORY` | `secureops-staging-frontend` | no | frontend repo name |

No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` should exist. If they do,
delete them and rely on OIDC. The workflow requires `id-token: write`.

---

## 3. Helm values (`charts/secureops/`)

### Image and replicas

| Value | Default | Notes |
|---|---|---|
| `backend.image.repository` | `""` | set to ECR URL in `values-staging.yaml` |
| `backend.image.tag` | `latest` | override with immutable `sha-*` |
| `backend.replicaCount` | `2` | HPA min is also 2 |
| `frontend.image.repository` | `""` | set to ECR URL |
| `frontend.image.tag` | `latest` | override with `sha-*` |
| `frontend.replicaCount` | `2` | |

### Backend env (rendered into the Deployment)

| Name | Value source | Notes |
|---|---|---|
| `APP_ENV` | values | `production` in cluster |
| `APP_DEBUG` | values | `false` |
| `LOG_CHANNEL` | values | `stderr` |
| `LOG_LEVEL` | values | `warning` |
| `DB_CONNECTION` | values | `pgsql` |
| `SKIP_MIGRATIONS` | values | `true`; Job owns migrations |
| `APP_KEY` | Secret | `base64:` Laravel key |
| `APP_URL` | Secret | public HTTPS URL |
| `FRONTEND_URL` | Secret | public HTTPS URL |
| `CORS_ALLOWED_ORIGINS` | Secret | must match the SPA origin |
| `DB_HOST` | Secret | RDS endpoint |
| `DB_PORT` | Secret | `5432` |
| `DB_DATABASE` | Secret | `secureops` |
| `DB_USERNAME` | Secret | `secureops` |
| `DB_PASSWORD` | Secret | never in Git |

### Autoscaling / availability

| Value | Default | Notes |
|---|---|---|
| `backend.autoscaling.enabled` | `true` | needs metrics-server to work |
| `backend.autoscaling.minReplicas` | `2` | |
| `backend.autoscaling.maxReplicas` | `5` | |
| `backend.autoscaling.targetCPUUtilizationPercentage` | `70` | |
| `backend.podDisruptionBudget.enabled` | `true` | |
| `backend.podDisruptionBudget.minAvailable` | `1` | |
| `frontend.autoscaling.minReplicas` | `2` | |
| `frontend.autoscaling.maxReplicas` | `4` | |

### Secrets / External Secrets

| Value | Default | Notes |
|---|---|---|
| `secrets.create` | `false` | only for local/demo |
| `externalSecret.enabled` | `false` | set `true` in staging values |
| `externalSecret.refreshInterval` | `1m` | ESO poll interval |
| `externalSecret.storeName` | `aws-secretsmanager` | ClusterSecretStore name |
| `externalSecret.appSecretId` | `secureops/staging/app` | app key/URLs |
| `externalSecret.dbSecretId` | `secureops/staging/database` | DB creds |

### Migration Job

| Value | Default | Notes |
|---|---|---|
| `migrate.enabled` | `true` | |
| `migrate.backoffLimit` | `3` | |
| `migrate.activeDeadlineSeconds` | `300` | |

### Ingress

| Value | Default | Notes |
|---|---|---|
| `ingress.enabled` | `true` | |
| `ingress.className` | `alb` | |
| `ingress.host` | `""` | set real host in staging |
| `ingress.tls` | `[]` | host + `secretName` |
| `alb.ingress.kubernetes.io/certificate-arn` | — | ACM ARN, same region |
| `alb.ingress.kubernetes.io/ssl-redirect` | — | port string `"443"` |

---

## 4. Local compose / process env

### Root `.env.example`

| Name | Example | Notes |
|---|---|---|
| `APP_ENV` | `local` | |
| `APP_DEBUG` | `false` | |
| `APP_KEY` | empty | generate locally |
| `APP_URL` | `http://localhost:8000` | |
| `FRONTEND_URL` | `http://localhost:5173` | |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:5173` | |
| `DB_DATABASE` | `secureops` | |
| `DB_USERNAME` | `secureops` | |
| `DB_PASSWORD` | `<DB_PASSWORD>` | demo only; replace |
| `BACKEND_PORT` | `8000` | host port |
| `FRONTEND_PORT` | `5173` | host port |
| `SEED_ADMIN_EMAIL` | `admin@secureops.local` | |
| `SEED_ADMIN_PASSWORD` | `<CHANGE_ME>` | change immediately |
| `SEED_DEMO_CONTACTS` | `false` | demo data |

### Backend `.env.example` (additional)

| Name | Example | Notes |
|---|---|---|
| `APP_NAME` | `SecureOps` | |
| `APP_TIMEZONE` | `UTC` | |
| `APP_LOCALE` / `APP_FALLBACK_LOCALE` | `en` | |
| `APP_FAKER_LOCALE` | `en_US` | |
| `APP_MAINTENANCE_DRIVER` | `file` | |
| `BCRYPT_ROUNDS` | `12` | |
| `LOG_STACK` | `single` | |
| `SESSION_DRIVER` | `database` | |
| `SESSION_LIFETIME` | `120` | |
| `SESSION_ENCRYPT` | `false` | |
| `SESSION_DOMAIN` | `null` | |
| `BROADCAST_CONNECTION` | `log` | |
| `FILESYSTEM_DISK` | `local` | |
| `QUEUE_CONNECTION` | `database` | |
| `CACHE_STORE` | `database` | |
| `CACHE_PREFIX` | `secureops_` | |
| `MAIL_MAILER` | `log` | no real email locally |
| `MAIL_HOST` / `MAIL_PORT` | `127.0.0.1` / `2525` | |
| `MAIL_FROM_ADDRESS` / `MAIL_FROM_NAME` | example values | |

### Frontend `.env.example`

| Name | Default | Notes |
|---|---|---|
| `VITE_API_BASE_URL` | `/api/v1` | same-origin in Docker/K8s |
| `VITE_API_PROXY_TARGET` | `http://localhost:8000` | local Vite proxy only |

### Ops scripts (`ops/*.sh`)

| Name | Default | Notes |
|---|---|---|
| `AWS_REGION` | `ap-south-1` | |
| `CLUSTER_NAME` | `secureops-staging` | |
| `DB_INSTANCE` | `secureops-staging` | |
| `NAMESPACE` | `secureops-staging` | |
| `POWER_LOG` | `~/logs/secureops-power.log` | |
| `KUBECONFIG` | `~/.kube/config` | |

---

## Sanitization rules for the public portfolio

Replace before publishing:

| Real value | Replace with |
|---|---|
| `<ACCOUNT_ID>` | `<ACCOUNT_ID>` |
| private GitHub repo URL | `https://github.com/<owner>/<repo>.git` |
| full ACM ARN | `<ACM_CERT_ARN>` |
| any real hostname you do not want public | `<DOMAIN>` |
| `<CHANGE_ME>` | `<CHANGE_ME>` |
| `<DB_PASSWORD>` | `<DB_PASSWORD>` |
| demo `APP_KEY` | `<APP_KEY>` |

Keep the hostname only if you deliberately want it in the portfolio.
