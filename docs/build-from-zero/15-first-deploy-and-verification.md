# 15 — First Deploy and Verification

**Goal:** prove the whole chain works: image → Git tag → ArgoCD → pods → secret
→ database → HTTPS.

**Time:** 10–20 minutes after the first sync.
**Cost:** running cluster. **Safety:** deploy is `STATE-CHANGING`; do not run
destructive DB commands on data you care about.

---

## 15.1 Pre-flight checklist

```bash
# Cluster reachable
kubectl cluster-info
kubectl get nodes

# ArgoCD healthy
kubectl -n argocd get pods

# Images exist and tags are pinned
aws ecr describe-images --repository-name secureops-staging-backend \
  --region ap-south-1 --query 'imageDetails[].[imageTags[0],imagePushedAt]' --output table

# Values point at a real sha tag, not latest
grep -n 'tag:' charts/secureops/values-staging.yaml
```

Do not continue if `tag: latest`, if ECR has no matching tag, or if nodes are
`NotReady`.

---

## 15.2 Trigger the first sync

If the Application exists but has not synced:

```bash
kubectl -n argocd get application secureops-staging
kubectl -n argocd patch application secureops-staging \
  --type merge -p '{"operation":{"sync":{}}}'
```

Watch:

```bash
kubectl -n argocd get application secureops-staging -w
kubectl -n secureops-staging get pods -w
```

Expected events:

1. ExternalSecret syncs (wave `-10`).
2. Migration Job runs (wave `-5`) and completes.
3. Backend/frontend Deployments roll out.
4. Ingress creates/updates the ALB.

---

## 15.3 Verify Kubernetes objects

```bash
kubectl -n secureops-staging get deploy,po,svc,ingress,hpa,pdb,job
kubectl -n secureops-staging get externalsecret
kubectl -n secureops-staging describe externalsecret secureops-staging
```

Expected:

- 2 backend pods and 2 frontend pods `Running` and `Ready`.
- 1 completed migration Job.
- ExternalSecret `SecretSynced`.
- Services `ClusterIP`.
- Ingress has an ALB address.
- HPA objects exist (but see the metrics warning below).
- PDB exists for backend.

If pods are not ready:

```bash
kubectl -n secureops-staging describe pod <pod>
kubectl -n secureops-staging logs <pod> --tail=100
kubectl -n secureops-staging logs job/<migrate-job> --tail=100
```

---

## 15.4 Verify the secret exists and is not in Git

```bash
kubectl -n secureops-staging get secret
kubectl -n secureops-staging get secret secureops-staging-app -o jsonpath='{.data.APP_KEY}' | base64 -d | head -c 12; echo
```

Do **not** print full secrets into logs or screenshots. Confirm the key exists
and starts with `base64:`.

Cross-check the source:

```bash
aws secretsmanager get-secret-value \
  --secret-id secureops/staging/app \
  --region ap-south-1 \
  --query SecretString --output text | jq 'keys'
```

---

## 15.5 Verify the database and seed the admin

The migration Job should have created the schema. Check from a temporary pod
(the image already has `psql`? if not, use a `postgres` client image):

```bash
kubectl -n secureops-staging run pgcheck --rm -it --restart=Never \
  --image=postgres:16-alpine -- \
  psql "$DATABASE_URL" -c '\dt'
```

Simpler and more reliable: exec into a backend pod and use Laravel:

```bash
kubectl -n secureops-staging exec deploy/secureops-staging-backend -- \
  php artisan migrate:status

kubectl -n secureops-staging exec deploy/secureops-staging-backend -- \
  php artisan db:seed --force
```

`DatabaseSeeder` creates an admin from `SEED_ADMIN_EMAIL` /
`SEED_ADMIN_PASSWORD`, defaulting to `admin@secureops.local` /
`<CHANGE_ME>`. **Change that password immediately** after first login. The
default is public knowledge.

If you want deterministic data in staging, set seed env vars in the app secret
rather than relying on defaults.

---

## 15.6 Verify through the ALB

```bash
HOST=staging.example.com
curl -sS -o /dev/null -w 'root: %{http_code}\n' "https://$HOST/"
curl -sS -o /dev/null -w 'health: %{http_code}\n' "https://$HOST/api/v1/health"
curl -sS "https://$HOST/api/v1/health" | jq
```

Expected health payload includes an `ok`/database status. A `500` on health while
`/up` is `200` usually means the DB connection or app key is wrong.

Check the SPA loads and calls the API:

```bash
curl -sS "https://$HOST/" | grep -i '<title>'
curl -sS -o /dev/null -w 'login page: %{http_code}\n' "https://$HOST/login"
```

---

## 15.7 Functional smoke test

Use the UI or the API:

1. Open `https://<host>/`.
2. Log in with the seeded admin.
3. Change the password.
4. Create a contact.
5. Refresh and confirm it persists (proves DB write/read through the real path).
6. Create/edit a log entry.
7. Log out and back in.

API-only variant:

```bash
TOKEN=$(curl -sS -X POST "https://$HOST/api/v1/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@secureops.local","password":"<CHANGE_ME>"}' | jq -r '.token')

curl -sS "https://$HOST/api/v1/contacts" -H "Authorization: Bearer $TOKEN" | jq '.data | length'
```

If login returns 419/CSRF, you are hitting the SPA route rather than the API, or
cookies/CORS are misconfigured. Check `CORS_ALLOWED_ORIGINS` and `FRONTEND_URL`.

---

## 15.8 Verify observability endpoints exist

```bash
kubectl top pods -n secureops-staging   # fails without metrics-server
kubectl -n secureops-staging get hpa
```

If `kubectl top` fails, the HPA cannot scale on CPU. That is a real gap, not a
cosmetic one. Install metrics-server before relying on autoscaling.

---

## 15.9 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Pods `ImagePullBackOff` | bad ECR URL/tag or no egress | verify values, NAT, ECR |
| `CreateContainerConfigError` | Secret missing | fix ExternalSecret/waves |
| Migration Job fails | DB unreachable/credentials | check job logs and secret |
| Migration Job succeeds, app 500 | app key/URL/env wrong | inspect pod env and Laravel log |
| Login 401 | seed password differs | re-seed or reset via tinker |
| Contact not persisted | DB read-only/wrong DB | check DB host and `migrate:status` |
| `419` on API calls | CSRF/cookie domain mismatch | use token auth; fix CORS/URLs |
| Health 500, `/up` 200 | DB or key problem | check DB secret and logs |
| HPA `<unknown>` | metrics-server absent | install metrics-server |
| ALB 503 | no healthy targets | fix readiness and target health |

**Next:** day-2 operations in `16-operate-debug-and-observe.md`.
