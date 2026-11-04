# 13 — ArgoCD and GitOps

**Goal:** let the cluster pull its desired state from Git, so CI never needs
cluster credentials and drift is corrected automatically.

**Time:** 10–15 minutes. **Cost:** ArgoCD runs on the existing nodes.
**Safety:** `kubectl apply` is `STATE-CHANGING`; deleting Applications is
`DESTRUCTIVE` to the workloads they own.

---

## 13.1 Why pull-based deployment

In a push model, CI holds a kubeconfig or cluster-admin credential. That is a
large blast radius if the CI system is compromised.

In this pull model:

- CI pushes images to ECR only.
- A human (or automation) commits the new image tag to Git.
- ArgoCD, running inside the cluster, pulls the chart and reconciles.
- No CI job can delete a namespace or read cluster secrets.

The trade-off: Git becomes the deployment API, and ArgoCD itself must be
operated and secured.

---

## 13.2 Bootstrap

`argocd/bootstrap.sh`:

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/apps/staging.yaml
```

Run it after Terraform and kubeconfig:

```bash
cd <repo-root>
./argocd/bootstrap.sh
```

### Known bootstrap failure: CRD annotation too long

The upstream `install.yaml` includes an ApplicationSet CRD whose last-applied
annotation can exceed Kubernetes' 262144-byte limit:

```
metadata.annotations: Too long: may not be more than 262144 bytes
```

Fix: server-side apply the manifest instead of client-side apply:

```bash
kubectl apply --server-side -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Then re-run the rest of the bootstrap.

### Version pinning warning

The script uses `stable`, which is not a pinned version. A later bootstrap can
install a different ArgoCD. Pin a specific release tag for reproducibility.

---

## 13.3 Project and Application

`argocd/project.yaml` creates a project that allowlists:

- the private Git repository,
- the `secureops-staging` and `secureops-prod` namespaces on the in-cluster API.

`argocd/apps/staging.yaml` creates an Application:

```yaml
source:
  repoURL: https://github.com/<owner>/<private-repo>.git
  targetRevision: main
  path: charts/secureops
  helm:
    valueFiles: [values.yaml, values-staging.yaml]
destination:
  namespace: secureops-staging
syncPolicy:
  automated: { prune: true, selfHeal: true }
  syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

`prune: true` deletes resources removed from Git. `selfHeal: true` reverts manual
edits. Both are powerful; both can surprise you if you debug by editing live
objects.

---

## 13.4 Private repository access

ArgoCD runs in-cluster and must authenticate to the private GitHub repo. The
original setup used a GitHub PAT stored as an ArgoCD repository Secret. The
sanitized steps:

1. Create a fine-grained PAT with read access to the repository.
2. Store it in a Secret ArgoCD can read (do not commit it):

```bash
kubectl -n argocd create secret generic repo-secureops \
  --from-literal=type=git \
  --from-literal=url=https://github.com/<owner>/<repo>.git \
  --from-literal=username=<github-username> \
  --from-literal=password=<PAT>
kubectl -n argocd label secret repo-secureops \
  argocd.argoproj.io/secret-type=repository
```

3. Add the repo URL to the ArgoCD project allowlist (already in
   `argocd/project.yaml` for the original repo; change it if you fork).

Rotate the PAT like any other credential. For a public portfolio repo, ArgoCD
can read anonymously, so no PAT is needed.

---

## 13.5 Sync waves

The chart uses:

- ExternalSecret: wave `-10`.
- Migration Job: wave `-5`.
- Deployments: default `0`.

ArgoCD applies lower waves first. If the secret is not synced before the Job,
the Job fails with `CreateContainerConfigError`. If the values are changed
without preserving waves, you can reintroduce that race.

---

## 13.6 Verify

```bash
kubectl -n argocd get applications
kubectl -n argocd get application secureops-staging -o yaml | \
  grep -A20 'status:'

kubectl -n secureops-staging get pods
kubectl -n secureops-staging get externalsecret
kubectl -n secureops-staging get jobs
```

Expected: `Synced`, health `Healthy` (a cosmetic `Degraded` flag was observed in
the original setup despite no unhealthy resources — corroborate with pods and
HTTP, not the flag alone), 4 app pods running, ExternalSecret `SecretSynced`.

Force a sync (only after understanding why it is out of sync):

```bash
kubectl -n argocd patch application secureops-staging \
  --type merge -p '{"operation":{"sync":{}}}'
```

---

## 13.7 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `not permitted in project` | repo URL not in `sourceRepos` | update project allowlist |
| `repository not found` | ArgoCD lacks credentials | create/label repo Secret |
| `CreateContainerConfigError` | ExternalSecret not ready | check ESO, waves, logs |
| `sync-wave` ignored | resources applied by Helm, not ArgoCD | use the correct tool/path |
| Application `Degraded` but pods healthy | cosmetic/status quirk | verify HTTP; do not chase blindly |
| `metadata.annotations: Too long` | client-side apply on large CRD | server-side apply |
| Manual `kubectl edit` reverts | selfHeal enabled | change Git, not the live object |

**Next:** expose the app with ALB, ACM, and WAF in
`14-alb-ingress-tls-waf.md`.
