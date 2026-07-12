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
LS_CONTAINER="${LOCALSTACK_CONTAINER:-testinfra-localstack}"
KIND_DOCKER_NETWORK="${KIND_DOCKER_NETWORK:-kind}"
STACKS=("$@")
if [[ ${#STACKS[@]} -eq 0 ]]; then
  STACKS=(shared network backend eks)
fi

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"
export AWS_EC2_METADATA_DISABLED=true

uses_s3_backend() {
  grep -q 'backend "s3"' "$LIVE/shared/versions.tf" 2>/dev/null
}

# Mirror scripts/env.sh: prefer working localhost; fall back to container IP.
resolve_endpoint() {
  local preferred="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
  local ip="" endpoint=""

  if curl -sf --max-time 3 "${preferred}/_localstack/health" >/dev/null 2>&1; then
    echo "$preferred"
    return 0
  fi
  if docker inspect "$LS_CONTAINER" >/dev/null 2>&1; then
    ip="$(docker inspect -f '{{range $n,$c := .NetworkSettings.Networks}}{{if ne $n "kind"}}{{println $c.IPAddress}}{{end}}{{end}}' "$LS_CONTAINER" 2>/dev/null | awk 'NF{print; exit}')"
    if [[ -z "$ip" ]]; then
      ip="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${KIND_DOCKER_NETWORK}\").IPAddress }}" "$LS_CONTAINER" 2>/dev/null || true)"
    fi
    if [[ -n "$ip" && "$ip" != "<no value>" ]]; then
      endpoint="http://${ip}:4566"
      if curl -sf --max-time 3 "${endpoint}/_localstack/health" >/dev/null 2>&1; then
        echo "$endpoint"
        return 0
      fi
    fi
  fi
  echo "LocalStack unreachable (tried $preferred and container IP)." >&2
  return 1
}

sync_s3_backend_endpoints() {
  local endpoint="$1"
  local stack vf
  for stack in shared network backend eks; do
    vf="$LIVE/$stack/versions.tf"
    [[ -f "$vf" ]] || continue
    grep -q 'backend "s3"' "$vf" 2>/dev/null || continue
    python3 - "$vf" "$endpoint" <<'PY'
import pathlib, re, sys
path, ep = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
text2, _ = re.subn(r'(?m)^(\s*endpoint\s*=\s*)"[^"]*"', rf'\1"{ep}"', text, count=1)
text3, _ = re.subn(r'(?m)^(\s*dynamodb_endpoint\s*=\s*)"[^"]*"', rf'\1"{ep}"', text2, count=1)
path.write_text(text3)
PY
  done
}

ENDPOINT="$(resolve_endpoint)"
export LOCALSTACK_ENDPOINT="$ENDPOINT"
export TF_VAR_localstack_endpoint="$ENDPOINT"

if uses_s3_backend; then
  sync_s3_backend_endpoints "$ENDPOINT"
fi

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

  # Match env.sh: backend may flip local↔s3 or S3 endpoints may be rewritten.
  terraform -chdir="$dir" init -input=false -reconfigure -force-copy >/dev/null

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
