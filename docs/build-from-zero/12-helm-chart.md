# 12 — Helm Chart

**Goal:** turn the images and secrets into Kubernetes objects with one
parameterized chart.

**Time:** 15–30 minutes to understand; seconds to render.
**Cost:** $0 to render; cluster resources cost money.
**Safety:** `helm template`/`lint` are `READ-ONLY`; `helm install` is
`STATE-CHANGING`.

Chart: `charts/secureops/`.

---

## 12.1 Values layering

```text
values.yaml          # defaults, safe placeholders
values-staging.yaml  # real image URLs/tags, host, ExternalSecret IDs
values-prod.yaml     # template for a second environment (not deployed)
```

Helm merges left to right:

```bash
helm template secureops charts/secureops \
  -f charts/secureops/values.yaml \
  -f charts/secureops/values-staging.yaml \
  --namespace secureops-staging
```

The chart is normally rendered by ArgoCD, not installed by hand. Local rendering
is for review.

---

## 12.2 What the chart creates

| Template | Objects | Notes |
|---|---|---|
| `backend.yaml` | Deployment + Service | 2 replicas, non-root uid 82, probes, env from Secret |
| `frontend.yaml` | Deployment + Service | 2 replicas, nginx, `/tmp` emptyDir |
| `migrate-job.yaml` | Job | Helm pre-install/pre-upgrade hook + ArgoCD wave `-5` |
| `secrets.yaml` | (optional) Secret + ExternalSecret | ESO wave `-10` |
| `autoscaling.yaml` | HPAs + backend PDB | HPA needs metrics-server to function |
| `ingress.yaml` | Ingress | ALB class, `/api` → backend, `/` → frontend |
| `_helpers.tpl` | names/labels helpers | stable naming across objects |

---

## 12.3 Probes and lifecycle

Backend:

- Liveness: `GET /up` (Laravel's built-in health endpoint).
- Readiness: `GET /api/v1/health` (checks the app/DB path).
- `SKIP_MIGRATIONS=true` so the Deployment does not run migrations; the Job does.
- `readOnlyRootFilesystem: false` because Laravel writes to `storage/`. The
  container still runs as non-root with all capabilities dropped.

Frontend:

- Liveness/readiness: `GET /` (nginx serving the SPA).
- `emptyDir` mounted at `/tmp` so nginx can write pid/temp files with a
  read-only root filesystem.

The migration Job:

- Runs `php artisan migrate --force --no-interaction`.
- Has `helm.sh/hook: pre-install,pre-upgrade` and
  `argocd.argoproj.io/sync-wave: "-5"`.
- Waits for the Secret via wave `-10`.
- `backoffLimit: 3`, `activeDeadlineSeconds: 300`.

Why both Helm hook and ArgoCD wave: the same chart can be used by `helm` or by
ArgoCD. Each path needs its own ordering annotation.

---

## 12.4 Autoscaling and availability

- Backend HPA: 2–5 replicas at 70% CPU.
- Frontend HPA: 2–4 replicas at 70% CPU.
- Backend PDB: `minAvailable: 1` so voluntary disruptions cannot take both pods.

**Critical reality:** HPAs are only as good as the metrics API. This cluster did
**not** install metrics-server. `kubectl get hpa` showed the objects, but CPU
metrics were unavailable, so autoscaling was effectively blind. Install
metrics-server before claiming autoscaling works.

PDBs only protect against voluntary disruption (drains, upgrades). They do not
create capacity.

---

## 12.5 Ingress

`values-staging.yaml` overrides:

```yaml
ingress:
  host: "staging.example.com"
  tls:
    - hosts: ["staging.example.com"]
      secretName: app-tls
  annotations:
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: <ACM_CERT_ARN>
    alb.ingress.kubernetes.io/ssl-redirect: "443"
```

`ssl-redirect` is a **port string**, not a boolean. `"true"` causes a controller
parse error.

Paths:

- `/api` → backend Service port 80 → container 8080.
- `/` → frontend Service port 80 → container 8080.

ALB target type is `ip` (pod IPs directly), not `instance`.

---

## 12.6 Render and lint

```bash
helm lint charts/secureops -f charts/secureops/values-staging.yaml

helm template secureops charts/secureops \
  -f charts/secureops/values-staging.yaml \
  --namespace secureops-staging \
  > /tmp/rendered.yaml

grep -n 'kind:\|image:\|host:\|sync-wave' /tmp/rendered.yaml
```

Check specifically:

- `image.repository` and `image.tag` are your ECR URL and `sha-*` tag.
- No `latest`.
- Ingress has host/TLS/cert ARN.
- ExternalSecret has wave `-10`; migrate Job has wave `-5`.
- No plaintext secret values in the rendered output.

If you have `kubeconform`, validate:

```bash
kubeconform -strict -summary /tmp/rendered.yaml
```

---

## 12.7 Dry-run against the cluster

```bash
kubectl -n secureops-staging create namespace secureops-staging --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install secureops charts/secureops \
  -f charts/secureops/values-staging.yaml \
  --namespace secureops-staging \
  --dry-run=server
```

`--dry-run=server` validates against the API server (CRDs, webhooks, RBAC)
without changing resources. This is the strongest pre-flight check.

---

## 12.8 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `CreateContainerConfigError` | referenced Secret missing | check ExternalSecret and wave order |
| Migrate Job runs before secret | wave/hook ordering | secret `-10`, job `-5` |
| `ssl-redirect` parse error | boolean instead of port string | use `"443"` |
| `ImagePullBackOff` | wrong ECR URL/tag or node egress | check values, ECR, NAT |
| Pods OOMKilled | limits too low | inspect `describe pod`, raise limits |
| HPA shows `<unknown>` | metrics-server absent | install metrics-server |
| PDB blocks drain forever | minAvailable too strict for replicas | keep replicas ≥ 2 and minAvailable 1 |
| Frontend crash on read-only root | `/tmp` not writable | keep the `emptyDir` mount |

**Next:** deploy it through ArgoCD in `13-argocd-gitops.md`.
