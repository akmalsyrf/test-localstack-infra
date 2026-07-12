#!/usr/bin/env bash
# Standalone Terraform drift check against LocalStack (or any configured backend).
# Usage: check-drift.sh <dev|staging|production> [stack1 stack2 ...]
#
# Exit codes:
#   0 — all stacks have no pending changes (or only soft-reported failures already printed)
#   1 — usage / missing env
#   2 — at least one stack reported drift or plan failure
#
# Retries each stack up to 3 times to absorb transient LocalStack attribute reorder.
# Used by: scripts/verify-apply.sh and .github/workflows/drift-check.yml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:-}"
shift || true

if [[ -z "$ENV" || ! -d "$ROOT/terraform/live/$ENV" ]]; then
  echo "Usage: $0 <dev|staging|production> [stack ...]" >&2
  exit 1
fi

LIVE="$ROOT/terraform/live/$ENV"
ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
STACKS=("$@")
if [[ ${#STACKS[@]} -eq 0 ]]; then
  STACKS=(shared network backend eks)
fi

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"
export AWS_EC2_METADATA_DISABLED=true

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  PASS  $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL  $1"
}

check_drift() {
  local stack="$1"
  local dir="$LIVE/$stack"
  local plan_file="/tmp/drift-plan-${ENV}-${stack}.txt"
  local attempt rc=1

  if [[ ! -d "$dir" ]]; then
    fail "stack dir missing: $dir"
    return 0
  fi

  for attempt in 1 2 3; do
    set +e
    terraform -chdir="$dir" plan -input=false -no-color -detailed-exitcode -lock=false \
      -var="localstack_endpoint=${ENDPOINT}" >"$plan_file" 2>&1
    rc=$?
    set -e
    case "$rc" in
      0)
        ok "no drift in $stack"
        return 0
        ;;
      2)
        if [[ "$attempt" -lt 3 ]]; then
          echo "  ...  transient drift in $stack (attempt $attempt/3), retrying..."
          sleep 3
          continue
        fi
        fail "drift detected in $stack (plan wants changes)"
        echo "      see $plan_file"
        grep -E '^(  # |  [-+~]|Plan:|Terraform will)' "$plan_file" | head -n 60 || true
        return 0
        ;;
      *)
        fail "terraform plan failed for $stack (exit $rc)"
        tail -n 40 "$plan_file" >&2 || true
        return 0
        ;;
    esac
  done
}

echo "======== DRIFT CHECK: $ENV ========"
echo "Stacks: ${STACKS[*]}"
echo "LocalStack endpoint: $ENDPOINT"

for stack in "${STACKS[@]}"; do
  check_drift "$stack"
done

echo ""
echo "======== DRIFT SUMMARY ($ENV) ========"
echo "Passed:  $PASS"
echo "Failed:  $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Drift check FAILED"
  exit 2
fi

echo "Drift check PASSED"
exit 0
