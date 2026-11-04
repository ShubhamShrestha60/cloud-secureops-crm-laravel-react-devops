# 03 — Repository and Local Environment

**Goal:** run the application locally and prove the code, database, and
containers work *before* spending money on AWS.

**Time:** 15–30 minutes. **Cost:** $0 (local Docker only).
**Safety:** local-only; no cloud resources are created.

---

## 3.1 Create the local environment file

```bash
cp .env.example .env
```

Edit `.env` and set a local-only database password:

```dotenv
APP_ENV=local
APP_DEBUG=true
APP_URL=http://localhost:8000
FRONTEND_URL=http://localhost:5173
CORS_ALLOWED_ORIGINS=http://localhost:5173

DB_DATABASE=secureops
DB_USERNAME=secureops
DB_PASSWORD=local-only-<DB_PASSWORD>

BACKEND_PORT=8000
FRONTEND_PORT=5173

SEED_ADMIN_EMAIL=admin@secureops.local
SEED_ADMIN_PASSWORD=<CHANGE_ME>
SEED_DEMO_CONTACTS=true
```

Generate an application key. Laravel expects `base64:` followed by 32 random
bytes encoded in base64:

```bash
printf 'APP_KEY=base64:%s\n' "$(openssl rand -base64 32)" >> .env
```

If `.env` already has an empty `APP_KEY=`, remove that line first or replace it;
do not keep two `APP_KEY` entries.

> `.env` is gitignored. Never commit it. The values above are local defaults;
> `<CHANGE_ME>` must never be used in a shared or public environment.

---

## 3.2 Build the images

```bash
docker compose build
```

What this does:

- `backend/Dockerfile`: PHP 8.3 + Composer dependencies + nginx + php-fpm +
  supervisor, runs as `www-data` on port 8080.
- `frontend/Dockerfile`: Node 20 build stage → nginx runtime on port 8080.
- `database`: stock `postgres:16-alpine`.

If the build fails, read the first error, not the last. Common causes:
Docker daemon not running, no permission to the socket, or a Composer platform
mismatch (the project pins `config.platform.php = 8.3`).

---

## 3.3 Start the stack

```bash
docker compose up -d
docker compose ps
```

Expected: `secureops-db` healthy, `secureops-backend` healthy (may take ~60 s
for the first migration/startup), `secureops-frontend` up.

If the frontend starts before the backend is healthy, that is harmless locally:
nginx serves the SPA and proxies `/api` on request. Refresh once the backend is
healthy.

Logs:

```bash
docker compose logs -f backend
docker compose logs -f frontend
docker compose logs -f database
```

---

## 3.4 Verify locally (Layer 1–3)

### Layer 1 — containers

```bash
docker compose ps
```

### Layer 2 — HTTP

```bash
curl -s -o /dev/null -w 'backend /up: %{http_code}\n' http://localhost:8000/up
curl -s -o /dev/null -w 'backend health: %{http_code}\n' http://localhost:8000/api/v1/health
curl -s -o /dev/null -w 'frontend /: %{http_code}\n' http://localhost:5173/
```

Expected: `200` for all three.

### Layer 3 — application behavior

```bash
curl -s -X POST http://localhost:8000/api/v1/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"nobody@example.invalid","password":"wrongwrong00"}' \
  -o /dev/null -w 'bad login: %{http_code}\n'
```

Expected: `422`. A 422 proves the API and database path are alive without
needing a real password. A 500 means the database or app key is wrong.

Then open `http://localhost:5173/` in a browser and log in with the seed admin
credentials from `.env` (local only).

---

## 3.5 Seed and inspect data

Migrations normally run at container start. If you need to run them explicitly:

```bash
docker compose exec backend php artisan migrate --force
docker compose exec backend php artisan db:seed --force
```

Counts:

```bash
docker compose exec backend php artisan tinker --execute='
echo "users=".\App\Models\User::count().PHP_EOL;
echo "contacts=".\App\Models\Contact::count().PHP_EOL;
echo "logs=".\App\Models\ActivityLog::count().PHP_EOL;
'
```

The original staging drill used `users=2`, `contacts=13`, `logs=13`. Local counts
may differ depending on seeders.

---

## 3.6 Run tests locally

Backend:

```bash
docker compose exec backend php artisan test
docker compose exec backend ./vendor/bin/pint --test
```

Frontend (requires Node 20 on the host, or use a throwaway Node container):

```bash
cd frontend
npm ci --no-audit --no-fund
npm run lint
npm run test -- --run
npm run build
cd ..
```

CI is the authority. If local tests fail only because of missing host Node,
trust CI; if they fail in Docker, fix them before pushing.

---

## 3.7 Stop and clean up

```bash
docker compose down
```

Keep the database volume if you want your local data:

```bash
# DESTRUCTIVE: removes local database data
docker compose down -v
```

Never run `down -v` against anything you care about.

---

## 3.8 Common local failures

| Symptom | Cause | Fix |
|---|---|---|
| `Set DB_PASSWORD in .env` | variable missing | add `DB_PASSWORD` to `.env` |
| `APP_KEY` missing / cipher error | key not generated | generate and set `APP_KEY` |
| Backend 500 | DB not ready or wrong password | check `docker compose logs database` |
| Port already allocated | another service on 8000/5173 | change `BACKEND_PORT`/`FRONTEND_PORT` |
| Frontend 502 on `/api` | backend not up yet | wait for backend health, retry |
| `permission denied` on Docker socket | user not in `docker` group | `sudo usermod -aG docker $USER` and re-login |

**Next:** create remote Terraform state in `04-aws-bootstrap-and-remote-state.md`.
