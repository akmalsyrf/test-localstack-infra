#!/usr/bin/env bash
# Category: checks
# Fail fast if LocalStack is unhealthy or glacially slow (CI contention signal).
# Usage: check-localstack-latency.sh [max_seconds]
# Env: LOCALSTACK_ENDPOINT (default http://localhost:4566), AWS_DEFAULT_REGION
set -euo pipefail

MAX_SECONDS="${1:-5}"
ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_EC2_METADATA_DISABLED=true

# Brief retry: Kind create can briefly starve LocalStack CPU; give it a few seconds.
HEALTH_OK=0
for _ in $(seq 1 30); do
  if curl -sf --max-time 3 "$ENDPOINT/_localstack/health" >/dev/null; then
    HEALTH_OK=1
    break
  fi
  sleep 2
done
if [[ "$HEALTH_OK" -ne 1 ]]; then
  echo "::error::LocalStack health endpoint unreachable at $ENDPOINT" >&2
  docker compose ps 2>/dev/null || true
  exit 1
fi

START="$(date +%s)"
set +e
# Client-side timeout: do not hang for minutes if LocalStack/Docker is wedged.
timeout 10 aws --endpoint-url="$ENDPOINT" --region "$REGION" s3 ls >/dev/null 2>&1
RC=$?
set -e
ELAPSED=$(( $(date +%s) - START ))

echo "LocalStack s3 ls took ${ELAPSED}s (rc=$RC, budget=${MAX_SECONDS}s)"

if [[ "$RC" -ne 0 ]]; then
  echo "::error::LocalStack s3 ls failed (exit $RC) after ${ELAPSED}s — Docker/LocalStack may be wedged." >&2
  exit 1
fi

if [[ "$ELAPSED" -gt "$MAX_SECONDS" ]]; then
  echo "::error::LocalStack responded slowly (${ELAPSED}s > ${MAX_SECONDS}s). Likely CPU/Docker contention (e.g. Kind + LocalStack on a small runner)." >&2
  exit 1
fi

exit 0
