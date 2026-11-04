# Error → Cause → Fix

Exact messages seen or expected in this stack. Search this page before changing
code.

## AWS CLI / credentials / clock

| Error | Cause | Fix |
|---|---|---|
| `An error occurred (InvalidSignatureException)` | host clock skewed >5 min | `sudo chronyc -a makestep`; retry |
| `RequestTimeTooSkewed` | same | fix clock, then retry |
| `SignatureDoesNotMatch` | wrong secret/region or clock | check profile/region and clock |
| `Unable to locate credentials` | no profile/env/instance role | `aws configure` or export `AWS_PROFILE` |
| `AccessDenied` on a write | IAM policy too narrow | inspect the action/resource in the message |
| `ExpiredToken` | temporary creds expired | re-auth / refresh SSO |

## Terraform

| Error | Cause | Fix |
|---|---|---|
| `Error acquiring the state lock` | interrupted run left a lock | confirm no run is active; `terraform force-unlock <ID>` |
| `NoSuchBucket` on init/plan | state bucket deleted or renamed | restore bucket/state before continuing |
| `Failed to get existing workspaces: ...` | backend misconfigured or no access | check `backend.tf`, bucket, region, credentials |
| `Unsupported argument` / `Invalid reference` | provider/module version drift | `terraform init -upgrade`; check `versions.tf` |
| `Error: creating ...: InvalidParameterValue` | bad var value | read the field named in the message |
| `DependencyViolation` deleting VPC/SG | leftover ALB/ENI/NAT | delete dependencies, retry |
| `BucketNotEmpty` deleting ECR | images remain | empty repo or `force_delete = true` |
| `InvalidParameterValue: DB ... deletion protection` | RDS protection on | disable protection, retry |
| `plan` shows destroy/recreate unexpectedly | immutable field changed (e.g. name) | inspect plan before applying |
| `Error: Backend initialization required` | new backend config | `terraform init -reconfigure` if intentional |

## EKS / kubectl

| Error | Cause | Fix |
|---|---|---|
| `error: You must be logged in to the server (Unauthorized)` | stale kubeconfig/token | `aws eks update-kubeconfig ...` |
| `could not find the requested resource` | CRD not installed / wrong API version | install controller/CRD |
| Nodes `NotReady` | CNI/add-on/IP exhaustion | check `aws-node` logs, subnet IPs |
| Pods `Pending` | insufficient CPU/memory or node group at 0 | wake/scale nodes; lower requests |
| `ImagePullBackOff` | wrong ECR URL/tag or no egress | verify values, NAT, ECR auth |
| `CreateContainerConfigError` | referenced Secret/ConfigMap missing | check ExternalSecret; fix waves |
| `CrashLoopBackOff` | app/config/db failure | `logs --previous`, `describe` |
| `OOMKilled` | memory limit exceeded | raise limit; investigate leak |
| `FailedMount` | missing volume/secret/PVC | describe pod events |
| `unable to drain node ... pod evicted` | PDB blocks eviction | keep replicas ≥2, minAvailable 1 |
| `kubectl top` fails | metrics-server absent | install metrics-server |
| HPA `<unknown>` | no metrics API | metrics-server |
| `forbidden ... cannot patch resource` | RBAC | use the right role/kubeconfig |

## ArgoCD

| Error | Cause | Fix |
|---|---|---|
| `application ... is not permitted in project` | repo/namespace not allowlisted | update `argocd/project.yaml` |
| `repository not found` / auth error | private repo creds missing | create/label repo Secret |
| `metadata.annotations: Too long` | client-side apply on large CRD | `kubectl apply --server-side` |
| `one or more synchronization tasks are not valid` | invalid manifest | `helm template`, kubeconform |
| `Failed to load target state` | repo path/branch/values wrong | check Application source |
| Application `Degraded` but pods healthy | status quirk/cosmetic | verify HTTP and pod readiness |
| Manual edit reverted | `selfHeal: true` | change Git |
| Resources stuck `Progressing` | Job/Deployment not healthy | inspect the specific resource |
| `context deadline exceeded` on sync | slow image pull/migration | check events, increase retry/backoff |

## External Secrets / secrets

| Error | Cause | Fix |
|---|---|---|
| ExternalSecret `SecretSyncedError` | store/secret/permission issue | check ESO logs and IRSA |
| `AccessDeniedException` from Secrets Manager | IRSA trust/policy wrong | fix service account/role |
| `Secret not found` | wrong secret ID/region | match Terraform output |
| App `No application encryption key` | `APP_KEY` missing | fix app secret, restart |
| `Unsupported cipher or incorrect key length` | bad `APP_KEY` format | use `base64:<32-byte key>` |
| Secret updated, app unchanged | env read at startup | `rollout restart` |
| `CreateContainerConfigError` before ESO sync | wave ordering | secret `-10`, migrate `-5` |

## CI / release

| Error | Cause | Fix |
|---|---|---|
| Pint diff | formatting | `./vendor/bin/pint` |
| PHPUnit failure | code/test/DB assumption | reproduce locally |
| `npm ci` lock mismatch | lockfile out of sync | `npm install`, commit lock |
| Vitest failure | environment/test isolation | fix test |
| Hadolint `DL3018` | unpinned `apk add` | justified ignore |
| Shellcheck `SC2015` | `a && b || c` | rewrite |
| Gitleaks finding | committed secret or fixture | rotate if real; allowlist fixture |
| `Not authorized ... AssumeRoleWithWebIdentity` | OIDC trust/sub mismatch | fix trust and role variable |
| `tag ... already exists ... IMMUTABLE` | reused tag | new commit/new tag |
| Trivy gate fails | HIGH/CRITICAL CVE | patch/rebuild; do not lower threshold |
| `GetDownloadUrlForLayer` denied | ECR pull permission | add to release role |
| SARIF upload fails | permission | `security-events: write` |

## Containers

| Error | Cause | Fix |
|---|---|---|
| `host not found in upstream "backend"` | nginx resolves at startup | resolver + variable upstream |
| `permission denied` on nginx temp | non-root without writable dirs | create/chown `/tmp` dirs |
| `Read-only file system` for pid/temp | read-only root | mount `emptyDir` at `/tmp` |
| `Class "Faker\Factory" not found` | faker in dev deps only | production dependency |
| Composer platform conflict | PHP version mismatch | pin `config.platform.php` |
| DB wait loop never exits | wrong host/port/SG | check env and security group |

## ALB / TLS / DNS / WAF

| Error | Cause | Fix |
|---|---|---|
| `couldn't auto-discover subnets` | missing subnet tags | add `kubernetes.io/role/elb` etc. |
| No ALB created | controller not running/IRSA wrong | check controller logs |
| `ssl-redirect` parse error | boolean instead of port | use `"443"` |
| TLS handshake failure | cert not ISSUED/wrong region | validate ACM in ALB region |
| ALB `503` | no healthy targets | fix readiness/port/SG |
| ALB `502` | backend crash/wrong port | logs and targetPort |
| Targets `unhealthy` | health path/SG | check target health reason |
| `CertificateNotFound` | ARN invalid/region mismatch | re-check ARN |
| DNS not resolving | missing/wrong record/propagation | `dig`, compare ALB DNS |
| WAF blocks valid request | managed rule false positive | inspect sampled requests; scope |
| WAF association fails | ALB absent/tag mismatch | create Ingress first |

## Database / backup / restore

| Error | Cause | Fix |
|---|---|---|
| `could not connect to server` | SG/subnet/DB down | check RDS status, SG, host/port |
| `password authentication failed` | secret/rotation mismatch | verify secret and restart pods |
| `relation ... does not exist` | migrations not run | check migration Job |
| Migrate Job fails | DB not ready/creds | wait for RDS; check logs |
| Restored DB unreachable | default VPC/no SG | pass subnet group + SG |
| Restore counts differ | snapshot timing | compare timestamps |
| Cannot decrypt after restore | different `APP_KEY` | restore matching key |
| RDS restarts after a week | AWS auto-restart of stopped DB | snapshot/delete for long pause |

## Teardown

| Error | Cause | Fix |
|---|---|---|
| ALB still exists after cluster delete | controller gone first | delete listener/LB/TG manually |
| `DependencyViolation` on VPC | leftover ENI/ALB | find/delete dependencies |
| New charges after destroy | snapshots/EIP/logs/ECR | orphan sweep |
| Cannot delete state bucket | versioned objects | delete all versions first |
| Lost state | bucket deleted early | restore backup; manual cleanup otherwise |
