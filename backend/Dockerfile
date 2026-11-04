# Production Dockerfile for SecureOps Laravel API (EKS-ready).
# Multi-stage: vendor builds deps, runtime serves on 8080 as non-root www-data.
# No secrets baked in: config caching + migrations happen at runtime (entrypoint)
# or via Helm pre-upgrade Job when SKIP_MIGRATIONS=true.
# Port 8080 (not 80) so the image can run as non-root + read-only-ish on K8s.

FROM php:8.5-fpm-alpine AS vendor

# hadolint ignore=DL3018
# apk upgrade first: pulls patched OS libs (libexpat, pcre2) regardless of base snapshot age.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libzip-dev \
    unzip \
    git \
    oniguruma-dev \
    postgresql-dev \
    linux-headers

RUN docker-php-ext-install pdo_pgsql mbstring zip exif pcntl opcache \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www

# Layer cache: deps first, source second.
COPY composer.json composer.lock ./
RUN composer install --no-interaction --no-autoloader --no-scripts --no-dev --prefer-dist

COPY . .
# hadolint ignore=SC2015
RUN composer dump-autoload --optimize --no-dev \
    && composer check-platform-reqs --no-dev || true

FROM php:8.5-fpm-alpine AS runtime

WORKDIR /var/www

# hadolint ignore=DL3018
RUN apk upgrade --no-cache \
    && apk add --no-cache \
    nginx \
    supervisor \
    wget \
    libpng \
    libjpeg-turbo \
    freetype \
    libzip \
    libpq \
    oniguruma \
    && mkdir -p /var/log/supervisor /var/log/nginx /run/nginx /var/tmp/nginx /var/lib/nginx/logs /var/lib/nginx/tmp \
    && rm -f /etc/nginx/conf.d/default.conf /etc/nginx/http.d/default.conf

COPY --from=vendor /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=vendor /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/
COPY --from=vendor /usr/bin/composer /usr/bin/composer
COPY --from=vendor /var/www /var/www

COPY docker/php/opcache.ini /usr/local/etc/php/conf.d/opcache.ini
COPY docker/php/php.ini /usr/local/etc/php/conf.d/secureops.ini
COPY docker/nginx/default.conf /etc/nginx/http.d/default.conf
COPY docker/supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chown -R www-data:www-data /var/www/storage /var/www/bootstrap/cache /var/log/nginx /var/log/supervisor /run/nginx /var/tmp/nginx /var/lib/nginx \
    && chmod -R ug+rwx /var/www/storage /var/www/bootstrap/cache

# Non-root from here on. K8s securityContext should still set runAsNonRoot: true.
USER www-data

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/up | grep -q "OK" || wget -qO- http://127.0.0.1:8080/up | grep -q '"status"' || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
