# 10 — CI Pipeline

**Goal:** catch code, container, and secret problems on every pull request
without touching AWS.

**Time:** under ~5 minutes per run. **Cost:** GitHub Actions minutes (free tier
for public repos; private usage applies). **Safety:** read-only.

Workflow: `.github/workflows/ci.yml`.

---

## 10.1 Triggers and permissions

```yaml
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

permissions:
  contents: read
```

Why this shape:

- No `id-token: write` and no AWS credentials. CI must not be able to deploy.
- Pull requests cannot push images or change infrastructure.
- Concurrency cancels superseded runs on the same ref.

---

## 10.2 Jobs

### `backend` — Pint + PHPUnit

- PHP 8.3, `mbstring`, `pdo_sqlite`, `sqlite3`.
- `composer install`
- `./vendor/bin/pint --test` (style check, does not rewrite files)
- `php artisan test --colors=never`

### `frontend` — ESLint + Vitest + Build

- Node 20 with npm cache from `frontend/package-lock.json`.
- `npm ci --no-audit --no-fund` (lockfile-exact install).
- `npm run lint`
- `npm run test -- --run`
- `npm run build` (catches Vite/build-time errors ESLint misses)

### `containers` — Hadolint + Shellcheck + Compose

Runs after backend and frontend pass.

- Hadolint on both Dockerfiles.
- Shellcheck on `backend/docker/entrypoint.sh`.
- `docker compose config --quiet` validates the local compose file.

### `secrets` — Gitleaks

Checks out full history (`fetch-depth: 0`) and scans for committed secrets.
This is why accidental `.env` commits are caught before merge.

---

## 10.3 Reproduce CI locally

Run these from the repository root.

```bash
# Backend
cd backend
composer install
./vendor/bin/pint --test
php artisan test

# Frontend
cd ../frontend
npm ci --no-audit --no-fund
npm run lint
npm run test -- --run
npm run build

# Containers
cd ..
docker build -t secureops-backend:ci ./backend
docker build -t secureops-frontend:ci ./frontend
docker compose config --quiet
shellcheck backend/docker/entrypoint.sh   # if installed
```

If you do not have PHP or Node on the host, use the Docker images or trust CI.
The important rule: **do not push until the same checks pass locally or in a
draft PR.**

---

## 10.4 What CI deliberately does not do

- It does not build or push production images. That is the release workflow.
- It does not deploy. ArgoCD owns deployment.
- It does not run Trivy. Image scanning happens in the release pipeline on the
  exact image that would be pushed.
- It does not run `npm audit` (a known gap; see the backlog).
- It does not run SAST/DAST or image signing (also backlog).

---

## 10.5 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Pint fails | formatting drift | run `./vendor/bin/pint` and commit the result |
| PHPUnit fails on SQLite | DB-specific SQL | use portable queries or mock the DB |
| `npm ci` fails | lockfile out of sync | run `npm install` locally and commit `package-lock.json` |
| Vitest fails only in CI | timezone/environment assumptions | fix test isolation, not the CI runner |
| Hadolint DL3018 | unpinned `apk add` | use the existing `# hadolint ignore=DL3018` where intentional |
| Shellcheck SC2015 | `a && b || c` pattern | rewrite the logic or add a justified disable |
| Gitleaks hits a fixture | fake secret in test data | use an allowlist entry or change the fixture |
| Compose validation fails | YAML/env interpolation error | run `docker compose config` locally |

---

## 10.6 Branch protection (recommended)

In GitHub → Settings → Branches:

- Require CI to pass before merging to `main`.
- Require pull request reviews for changes to `infra/`, `charts/`, and
  `.github/workflows/`.
- Disallow force pushes to `main`.

This turns the workflow from advice into a gate.

**Next:** the release pipeline in `11-release-pipeline.md`.
