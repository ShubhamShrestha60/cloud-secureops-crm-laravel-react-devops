# 09 — Docker Images

**Goal:** build two production-shaped images: a Laravel API container and an
nginx-served React SPA. Both run as non-root on port 8080 and contain no
secrets.

**Time:** 5–15 minutes. **Cost:** $0 locally.
**Safety:** local build only; pushing is `STATE-CHANGING`.

---

## 9.1 Backend image (`backend/Dockerfile`)

### Stage 1 — `vendor`

- Base: `php:8.3-fpm-alpine`.
- `apk upgrade` first so OS packages are patched even if the base tag is old.
- Installs PHP extensions: `pdo_pgsql`, `mbstring`, `zip`, `exif`, `pcntl`,
  `opcache`, `gd`.
- Copies Composer from the official `composer:2` image.
- Installs dependencies with `--no-dev` **before** copying source, so the layer
  cache survives application-only changes.
- `composer dump-autoload --optimize --no-dev`.

### Stage 2 — `runtime`

- Same PHP base, plus `nginx`, `supervisor`, `wget`, and runtime libraries.
- Copies the built vendor tree and application source from stage 1.
- Copies project configs:
  - `backend/docker/php/php.ini` + `opcache.ini`
  - `backend/docker/nginx/default.conf`
  - `backend/docker/supervisor/supervisord.conf`
  - `backend/docker/entrypoint.sh`
- Creates writable nginx/run/log directories and chowns only what must be
  writable to `www-data`.
- Switches to `USER www-data`, exposes **8080**.

Why 8080: non-root processes cannot bind port 80. Using 8080 lets the container
run as an unprivileged user and behind a Service.

### Entrypoint behavior

`backend/docker/entrypoint.sh`:

1. Waits for `DB_HOST:DB_PORT` (up to `DB_WAIT_ATTEMPTS`).
2. Creates Laravel writable directories.
3. If `APP_KEY` is missing, generates an **ephemeral** key and warns. This is a
   local convenience; production must supply a stable key from Secrets Manager.
4. If `SKIP_MIGRATIONS=true`, skips migrations (the Helm Job owns them).
   Otherwise runs `php artisan migrate --force`.
5. Caches config/routes/views when `APP_ENV=production`.
6. `exec`s supervisord, which runs nginx + php-fpm.

Why `SKIP_MIGRATIONS=true` in Kubernetes: a rolling update can start several
pods at once. Running migrations in every pod races. A single migration Job
avoids that.

---

## 9.2 Frontend image (`frontend/Dockerfile`)

### Stage 1 — `build`

- Base: `node:20-alpine`.
- `apk upgrade` for patched OS libraries.
- `npm ci` from the lockfile, then `npm run build` (Vite).
- Output: `/app/dist`.

### Stage 2 — `runtime`

- Base: `nginx:stable-alpine`.
- Copies the built `dist` into `/usr/share/nginx/html`.
- Copies `frontend/nginx.conf` and `frontend/nginx-main.conf`.
- Changes the listen port from 80 to 8080.
- Creates nginx temp directories under `/tmp` and chowns them to `nginx`.
- Switches to `USER nginx`, exposes **8080**.

### nginx configuration notes

- SPA routing: `try_files $uri $uri/ /index.html`.
- Aggressive caching for `/assets/`, no-cache for `index.html`.
- Security headers, including a restrictive CSP.
- `/api/` proxy is a **local-compose fallback only**. It uses a `resolver` and a
  variable upstream so nginx can start even when the `backend` DNS name does not
  exist (for example in Kubernetes). Without that, nginx exits at startup with
  `host not found in upstream "backend"`.

On EKS, the ALB Ingress routes `/api/*` directly to the backend Service; the
frontend proxy is not used.

---

## 9.3 Build locally

```bash
docker build -t secureops-backend:local ./backend
docker build -t secureops-frontend:local ./frontend
```

Smoke-test the images:

```bash
docker run --rm -d --name be -p 18080:8080 \
  -e APP_ENV=local -e APP_KEY=base64:$(openssl rand -base64 32) \
  -e DB_HOST=host.docker.internal -e DB_PASSWORD=x \
  secureops-backend:local || true

docker run --rm -d --name fe -p 15173:8080 secureops-frontend:local
curl -s -o /dev/null -w 'frontend: %{http_code}\n' http://localhost:15173/
docker rm -f be fe
```

The backend smoke test may fail without a database; that is expected. The point
is to catch image-startup failures (nginx config, permissions) before CI.

---

## 9.4 Supply-chain decisions

- Base images are **tag-pinned but not digest-pinned**. Rebuilds can pull newer
  patched layers, which is good for CVEs but less reproducible. Digest pinning
  is a documented improvement, not current behavior.
- `apk upgrade` is deliberate: it picks up patched OS libraries even when the
  base tag is stale.
- Composer `platform.php` is pinned to 8.3 so lock resolution matches runtime.
- `fakerphp/faker` is a **production** dependency because factories may be used
  outside dev (this caused a real staging failure when it was dev-only).
- No secrets are baked into layers. Runtime secrets come from Kubernetes.

---

## 9.5 Common failures

| Symptom | Cause | Fix |
|---|---|---|
| `nginx: [emerg] host not found in upstream "backend"` | nginx resolved a non-existent name at startup | use the resolver + variable pattern |
| `Permission denied /var/lib/nginx/...` | running as non-root without writable dirs | create/chown nginx dirs in the image |
| `open() "/tmp/nginx.pid" failed (30: Read-only file system)` | read-only root without `/tmp` volume | mount `emptyDir` at `/tmp` |
| Composer resolves packages needing PHP 8.4 | platform not pinned | keep `config.platform.php = 8.3` |
| `Class "Faker\Factory" not found` in staging | faker only in `require-dev` | move to production deps |
| Image starts but app 500s | missing `APP_KEY` or DB env | check pod logs and secret sync |

**Next:** understand the pull-request checks in `10-ci-pipeline.md`.
