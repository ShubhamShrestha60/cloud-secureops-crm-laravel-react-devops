#!/bin/sh
# Wake the showcase stack: RDS started, nodes to 3, full verification.
# Expected lead time ~15 min. Exit non-zero naming the failed stage.
# See docs/sleep-wake.md.
set -eu

REGION="${AWS_REGION:-ap-south-1}"
CLUSTER="${CLUSTER_NAME:-secureops-staging}"
DB="${DB_INSTANCE:-secureops-staging}"
NAMESPACE="${NAMESPACE:-secureops-staging}"
SITE="${SITE_URL:-https://staging.shubham-shrestha.com.np}"
LOG="${POWER_LOG:-$HOME/logs/secureops-power.log}"

log() { printf '%s [wake] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }
wait_until() { # wait_until <seconds> <description> <command...>
  secs=$1; desc=$2; shift 2
  deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then log "$desc OK"; return 0; fi
    sleep 20
  done
  die "$desc timed out after ${secs}s"
}

mkdir -p "$(dirname "$LOG")"
if [ "${1:-}" = "--dry-run" ]; then
  log "dry-run: would start RDS $DB and scale nodegroup to 3, then verify"
  exit 0
fi

aws sts get-caller-identity --region "$REGION" >/dev/null \
  || die "AWS auth failed (check clock: date -u, then sudo chronyc -a makestep)"

NG=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'nodegroups[0]' --output text) || die "cannot list nodegroups"
[ -z "$NG" ] || [ "$NG" = "None" ] && die "no nodegroup found for $CLUSTER"

# 1. Database first (pods need it on boot).
log "starting RDS $DB (tolerating already-available)..."
aws rds start-db-instance --db-instance-identifier "$DB" --region "$REGION" >/dev/null 2>&1 \
  || log "start call refused (likely already available) — continuing"
wait_until 900 "RDS available" sh -c \
  "[ \"\$(aws rds describe-db-instances --db-instance-identifier \"$DB\" --region \"$REGION\" --query DBInstances[0].DBInstanceStatus --output text)\" = available ]"

# 2. Compute.
log "scaling nodegroup to desired 3..."
aws eks update-nodegroup-config --cluster-name "$CLUSTER" \
  --nodegroup-name "$NG" --region "$REGION" \
  --scaling-config minSize=2,maxSize=4,desiredSize=3 >/dev/null \
  || die "nodegroup scale-up rejected"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
wait_until 720 "3 nodes Ready" sh -c \
  "[ \"\$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')\" -ge 3 ]"
wait_until 720 "app pods Running" sh -c \
  "[ \"\$(kubectl -n \"$NAMESPACE\" get pods --no-headers 2>/dev/null | grep -cv 'Running')\" -eq 0 ]"

# 3. User-facing proof (demo-login shape check posts bad creds on purpose:
# a 422 ValidationException proves the API + DB path works end to end).
wait_until 300 "API health 200" sh -c \
  "[ \"\$(curl -s -m 15 -o /dev/null -w '%{http_code}' \"$SITE/api/v1/health\")\" = 200 ]"
[ "$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$SITE/")" = 200 ] \
  || die "SPA root did not return 200"
CODE=$(curl -s -m 15 -X POST "$SITE/api/v1/login" -H 'Content-Type: application/json' \
  -d '{"email":"nobody@example.invalid","password":"wrongwrong00"}' -o /dev/null -w '%{http_code}')
[ "$CODE" = "422" ] || die "login-shape check returned $CODE, expected 422"

log "DONE LIVE — shareable. Burn ~= \$199/mo while awake."
