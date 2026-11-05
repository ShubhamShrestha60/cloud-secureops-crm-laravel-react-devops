# Part IV — Containers and application delivery

> **Status:** The AWS environment was decommissioned on 2026-11-04. Live-state statements in this chapter describe the October 2026 deployment and are preserved as an as-built record.

## 5.1 Backend image (`backend/Dockerfile`, 79 lines, two stages)

**Vendor stage** (`php:8.3-fpm-alpine`): installs build deps (`apk`), PHP
extensions (`pdo_pgsql`, `gd`, `opcache`…), copies `composer:2`, then the
layer-cache trick — `COPY composer.json composer.lock` + `composer install
--no-autoloader --no-scripts --no-dev` *before* `COPY . .`, so code edits
don't invalidate the (slow) dependency layer. `dump-autoload --optimize`
finalizes. **Runtime stage**: fresh `php:8.3-fpm-alpine` + nginx + supervisor
+ `wget` (healthchecks), copies extensions/vendor/tree across, drops configs,
`chown`s every writable path (`storage/`, `bootstrap/cache`, nginx
log/run/tmp **and `/var/lib/nginx`** — the non-root crash fix), `USER
www-data`, port 8080, `HEALTHCHECK` on `/up`, entrypoint.

**Entrypoint contract** (`docker/entrypoint.sh`): wait-for-DB loop (TCP probe,
30 tries) → ephemeral `APP_KEY` fallback warning (dev only; prod must inject)
→ migrate **unless** `SKIP_MIGRATIONS=true` → `config:cache` in production →
`exec supervisord`. On EKS the chart sets `SKIP_MIGRATIONS=true` so the Helm
pre-upgrade **Job** owns migrations (avoids parallel-migrate races when HPA
scales during deploy). Locally the var is unset so `compose up` "just works."

Two production rules this file teaches: (1) **lockfiles resolve for the
runtime**, not the toolbox — `composer.json: platform.php=8.3` exists because
a newer-PHP container once resolved Symfony 8 (needs ≥8.4.1) and broke the
8.3 image build (Ch. 10); (2) `fakerphp/faker` is a **prod** dependency
because factories/seeders run in the prod image, where `--no-dev` removes
dev packages — and Laravel defines `fake()` only when Faker exists (Ch. 10).

## 5.2 Frontend image (`frontend/Dockerfile`, `nginx.conf`, `nginx-main.conf`)

`node:20-alpine` builds the Vite bundle (`npm ci` before `COPY . .`, same
cache trick); `nginx:stable-alpine` serves `dist/` as user `nginx` on 8080.
Three non-root adaptations, each a past crash: (1) `apk upgrade` in both
stages (patched `libexpat`/`pcre2` regardless of base snapshot); (2) custom
`nginx-main.conf` moving pid + all temp paths under `/tmp` (stock paths are
root-owned; `/run/nginx.pid` killed the first EKS boot); (3) `/tmp` + config
dirs owned by `nginx`. The `/api/` proxy uses `resolver` + variable so nginx
**starts** where `backend` DNS doesn't exist (compose fallback preserved; on
EKS the Ingress routes `/api` before traffic ever reaches this block).
Security/caching headers: `nosniff`, `SAMEORIGIN`, immutable `/assets`,
never-cache `index.html`, same-origin default API base.

## 5.3 ECR discipline (tags, pulls, failures)

Push **only** immutable `sha-<12>` (the floating `latest` was removed after
it collided with immutability — Ch. 10). Pulls from nodes use the node role;
Trivy pulls use the release role (`GetDownloadUrlForLayer` included).
`ImagePullBackOff` triage order: name/tag typo → ECR repo exists? → node role
ECR rights → registry auth (pods don't log in; nodes do) — never "app bug"
until pulls succeed. Keep-20 prunes; quarantined tags were deleted by hand
once (`batch-delete-image`), because lifecycle is count-based, not
vulnerability-based.

## 5.4 Compose (dev loop only)

`docker-compose.yml` (header says never-prod, mean it): Postgres 16 +
backend (`SKIP_MIGRATIONS=false`, ports `8000:8080`) + frontend (`5173:8080`),
bridge network, `pgdata` volume, healthchecks with `depends_on`. `Makefile`:
`up/down/build/logs/ps/seed` (seed = admin + optional demo contacts).
Compose is where you reproduce app bugs; it proves nothing about EKS.

## 5.5 Helm chart (`charts/secureops/`)

`Chart.yaml` v0.1.0; `values.yaml` (base) ← `values-staging.yaml` (live:
ECR repos, pinned tags, ExternalSecret on, ingress host/TLS/ALB annotations)
← `values-prod.yaml` (template). Deep-merge semantics: staging *adds/overrides
keys* (e.g., `ingress.annotations` merges with base — verified by render).
Per template:

- `backend.yaml`: Deployment (2 replicas, non-root/seccomp/`drop ALL`,
  env-from-Secret for all 9 keys, liveness `/up` + readiness `/api/v1/health`,
  requests/limits) + ClusterIP Service `:80→8080`. Note
  `readOnlyRootFilesystem: false` + comment: Laravel needs `storage/` writes.
- `frontend.yaml`: same shape, `readOnlyRootFilesystem: true` + `emptyDir`
  `/tmp` (the read-only crash fix), user 101.
- `migrate-job.yaml`: Helm hook (`pre-install,pre-upgrade`, weight `-5`,
  delete-before/succeeded) **and** ArgoCD wave `-5`; `php artisan migrate
  --force`. Auto-cleaned after success (hook policy) — its disappearance is
  normal, not an error.
- `secrets.yaml`: plain Secret if `secrets.create` (demo only) XOR
  `ExternalSecret` (live) extracting both SM secrets, wave `-10` so the
  Secret exists before the migrate Job (the deadlock fix, Ch. 10).
- `ingress.yaml`: `alb` class, host-or-ALB-hostname rules (`/api`→backend,
  `/`→frontend), TLS block; base annotations carry healthcheck path/port and
  success codes; staging adds cert ARN, 443 listener, `ssl-redirect: "443"`
  (**string port — `"true"` fails reconcile**, Ch. 10).
- `autoscaling.yaml`: CPU-target HPAs (backend 2–5, frontend 2–4) + backend
  PDB `minAvailable: 1` (rolling updates never drop the last pod).

Render before pushing chart edits (READ-ONLY):
`helm template secureops charts/secureops -f …/values.yaml -f
…/values-staging.yaml -n secureops-staging [--show-only templates/X.yaml]`.

## 5.6 GitOps delivery (`argocd/`)

`project.yaml` (source allowlist = this repo; destinations = both namespaces),
`apps/staging.yaml` (auto-sync + selfHeal + prune, `CreateNamespace`,
`ServerSideApply`, retry backoff, ESO `ignoreDifferences`), `bootstrap.sh`
(one-time installer; note its history: relative-path fix, server-side CRD
apply for the oversized-applicationsets annotation, project URL fix).
`secureops-prod` Application was **deleted** (single-env decision); its yaml
removed from git so bootstrap never recreates it.

Delivery trace (source→running, Ch. 2 map applied): Release prints `sha-xxx`
→ human pins both `image.tag`s → push → ArgoCD poll (≤3 min; `refresh=hard`
annotation forces) → wave -10 Secret → wave -5 migrate → wave 0 Deployments
(new ReplicaSets, old drain) → HPA/PDB/Ingress converge. Verify: app
`Synced`, pods new hashes `Running`, `/api/v1/health` + `/` 200. Rollback =
revert tag lines. When ArgoCD is red, read Ch. 10 before touching anything —
every historical red had a non-obvious cause (project allowlist, missing
Secret, wave deadlock, int-vs-bool annotation).
