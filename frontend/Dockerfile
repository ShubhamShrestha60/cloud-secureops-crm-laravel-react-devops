# Production Dockerfile for SecureOps React frontend (EKS-ready).
# Stage 1 builds the Vite bundle; stage 2 serves it via nginx on 8080 as non-root.
# Same-origin /api proxy is for local compose only — on EKS the Ingress routes
# /api/* to the backend Service, so this proxy is a fallback.
FROM node:20-alpine AS build

# Patched OS libs (libexpat, pcre2) regardless of base snapshot age.
RUN apk upgrade --no-cache

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .
RUN npm run build

FROM nginx:stable-alpine AS runtime

COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY nginx-main.conf /etc/nginx/nginx.conf

# nginx:stable-alpine runs as root by default; use unprivileged port + user.
# 8080 matches backend convention and K8s non-root policy.
RUN apk upgrade --no-cache \
    && sed -i 's/listen 80 /listen 8080 /g' /etc/nginx/conf.d/default.conf \
    && mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp \
    && chown -R nginx:nginx /usr/share/nginx/html /etc/nginx/conf.d /etc/nginx/nginx.conf /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp \
    && chmod -R u+rX /usr/share/nginx/html

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/ | grep -q "SecureOps" || exit 1

CMD ["nginx", "-g", "daemon off;"]
