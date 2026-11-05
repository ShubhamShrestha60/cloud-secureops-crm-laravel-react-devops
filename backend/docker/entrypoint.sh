#!/bin/sh
set -eu

# Entrypoint: wait for DB, optionally migrate, cache config, exec supervisor.
# EKS/Helm pattern: set SKIP_MIGRATIONS=true in Deployment so a Helm
# pre-upgrade Job owns migrations (avoids parallel migrate races on scale-out).
# Local compose: leave SKIP_MIGRATIONS unset so `docker compose up` just works.

DB_HOST="${DB_HOST:-database}"
DB_PORT="${DB_PORT:-5432}"
MAX_ATTEMPTS="${DB_WAIT_ATTEMPTS:-30}"
SKIP_MIGRATIONS="${SKIP_MIGRATIONS:-false}"

echo "Waiting for database ${DB_HOST}:${DB_PORT}..."
attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  if php -r "\$c=@fsockopen(getenv('DB_HOST')?:'database',(int)(getenv('DB_PORT')?:5432)); if(\$c){fclose(\$c); exit(0);} exit(1);"; then
    echo "Database reachable."
    break
  fi
  echo "Attempt ${attempt}/${MAX_ATTEMPTS}: database not ready, sleeping 2s..."
  sleep 2
  attempt=$((attempt+1))
done

if [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
  echo "Database never became ready; continuing anyway (migrate may fail)."
fi

cd /var/www

mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views \
  storage/logs bootstrap/cache

# APP_KEY must come from Secrets Manager / K8s Secret in prod. Ephemeral fallback is dev-only.
if [ -z "${APP_KEY:-}" ] || [ "${APP_KEY:-}" = "base64:" ]; then
  echo "APP_KEY missing; generating ephemeral key (set APP_KEY in production)."
  GENERATED_KEY=$(php artisan key:generate --show 2>/dev/null || true)
  if [ -n "${GENERATED_KEY:-}" ]; then
    export APP_KEY="$GENERATED_KEY"
    echo "Ephemeral APP_KEY generated for this container run."
  else
    echo "WARNING: could not generate APP_KEY; encryption-dependent features may fail."
  fi
fi

if [ "$SKIP_MIGRATIONS" = "true" ]; then
  echo "SKIP_MIGRATIONS=true — skipping migrate (Helm Job owns it)."
else
  php artisan migrate --force --no-interaction || {
    echo "Migration failed; check DB credentials."
    exit 1
  }
fi

if [ "${APP_ENV:-production}" = "production" ]; then
  php artisan config:cache || true
  php artisan route:cache || true
  php artisan view:cache || true
else
  php artisan config:clear || true
  php artisan route:clear || true
  php artisan view:clear || true
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
