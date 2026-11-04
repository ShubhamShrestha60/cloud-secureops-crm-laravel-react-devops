#!/bin/sh
# Sleep the showcase stack: nodes to 0, RDS stopped.
# Burn asleep ~= $100/mo (EKS + ALB + WAF + storage). Nothing is deleted:
# ECR images, secrets, DNS, ACM cert, Terraform state all untouched.
# Idempotent: safe to re-run anytime. See docs/sleep-wake.md.
set -eu

REGION="${AWS_REGION:-ap-south-1}"
CLUSTER="${CLUSTER_NAME:-secureops-staging}"
DB="${DB_INSTANCE:-secureops-staging}"
NAMESPACE="${NAMESPACE:-secureops-staging}"
LOG="${POWER_LOG:-$HOME/logs/secureops-power.log}"

log() { printf '%s [sleep] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

mkdir -p "$(dirname "$LOG")"
DRY_RUN="${1:-}"
if [ "$DRY_RUN" = "--dry-run" ]; then
  log "dry-run: would scale nodegroup to 0 and stop RDS $DB"
  exit 0
fi

# Pre-flight: valid AWS auth (fails fast on clock skew).
aws sts get-caller-identity --region "$REGION" >/dev/null \
  || die "AWS auth failed (check clock: date -u, then sudo chronyc -a makestep)"

NG=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" \
  --query 'nodegroups[0]' --output text) || die "cannot list nodegroups"
[ -z "$NG" ] || [ "$NG" = "None" ] && die "no nodegroup found for $CLUSTER"
log "nodegroup: $NG"

# 1. Drain compute. Never kubectl-scale Deployments: ArgoCD self-heal owns
# pod counts and would revert it. Nodegroup to 0 is invisible to GitOps.
log "scaling nodegroup desired to 0..."
aws eks update-nodegroup-config --cluster-name "$CLUSTER" \
  --nodegroup-name "$NG" --region "$REGION" \
  --scaling-config minSize=0,maxSize=4,desiredSize=0 >/dev/null \
  || die "nodegroup scale-down rejected"

# 2. Stop the database. NOTE: AWS auto-restarts stopped RDS after 7 days.
log "stopping RDS $DB (tolerating already-stopped)..."
if ! aws rds stop-db-instance --db-instance-identifier "$DB" --region "$REGION" >/dev/null 2>&1; then
  log "stop call refused (likely already stopped) — continuing"
fi

# 3. Confirm.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
log "waiting for nodes to drain (10 min max)..."
deadline=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -z "$(kubectl get nodes --no-headers 2>/dev/null)" ]; then break; fi
  sleep 20
done
[ -z "$(kubectl get nodes --no-headers 2>/dev/null)" ] \
  || die "nodes still present after 10 min"

STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DB" \
  --region "$REGION" --query 'DBInstances[0].DBInstanceStatus' --output text)
[ "$STATUS" = "stopped" ] || [ "$STATUS" = "stopping" ] \
  || die "RDS status is $STATUS, expected stopped/stopping"

log "DONE asleep. Burn ~= \$100/mo. Wake with ops/wake.sh (~15 min)."
