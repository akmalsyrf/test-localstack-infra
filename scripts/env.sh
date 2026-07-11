#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:-}"
ACTION="${2:-apply}" # apply | destroy | plan

if [[ -z "$ENV" || ! -d "$ROOT/terraform/live/$ENV" ]]; then
  echo "Usage: $0 <dev|staging> [apply|destroy|plan]" >&2
  exit 1
fi

"$ROOT/scripts/sync-live.sh"

LIVE="$ROOT/terraform/live/$ENV"
# Apply order: shared → network → backend → eks (EKS needs VPC/subnets)
STACKS=(shared network backend eks)

uses_tfc_cloud() {
  grep -q 'cloud {' "$LIVE/shared/versions.tf" 2>/dev/null
}

uses_s3_backend() {
  grep -q 'backend "s3"' "$LIVE/shared/versions.tf" 2>/dev/null
}

stack_has_state() {
  local stack="$1"
  if uses_s3_backend || uses_tfc_cloud; then
    # Remote backends: probe via outputs after init (no local terraform.tfstate).
    terraform -chdir="$LIVE/$stack" init -input=false >/dev/null 2>&1 || return 1
    terraform -chdir="$LIVE/$stack" output -json >/dev/null 2>&1
    return $?
  fi
  local state="$LIVE/$stack/terraform.tfstate"
  [[ -f "$state" ]] || return 1
  # Empty / never-applied local state still "exists" as a file sometimes; require outputs.
  terraform -chdir="$LIVE/$stack" output -json >/dev/null 2>&1
}

apply_stack() {
  local stack="$1"
  local dir="$LIVE/$stack"
  local parallelism=10

  echo ""
  echo "======== APPLY: $ENV/$stack ========"
  terraform -chdir="$dir" init -input=false

  if [[ "$stack" == "backend" ]]; then
    parallelism=1
  fi
  terraform -chdir="$dir" apply -auto-approve -input=false -parallelism="$parallelism"
}

plan_stack() {
  local stack="$1"
  local dir="$LIVE/$stack"

  echo ""
  echo "======== PLAN: $ENV/$stack ========"
  terraform -chdir="$dir" init -input=false
  terraform -chdir="$dir" plan -input=false
}

destroy_stack() {
  local stack="$1"
  local dir="$LIVE/$stack"
  local parallelism=10

  echo ""
  echo "======== DESTROY: $ENV/$stack ========"
  terraform -chdir="$dir" init -input=false

  if [[ "$stack" == "backend" ]]; then
    parallelism=1
  fi
  terraform -chdir="$dir" destroy -auto-approve -input=false -parallelism="$parallelism"
}

# Local backend: dependent stacks read sibling terraform.tfstate via
# terraform_remote_state. Ephemeral CI (and fresh checkouts) have no state until
# apply — so plan must apply upstream stacks first.
ensure_upstream_state_for_plan() {
  local stack="$1"
  case "$stack" in
    backend)
      for dep in shared network; do
        if ! stack_has_state "$dep"; then
          echo "==> plan needs $dep state (terraform_remote_state); applying $dep first..."
          apply_stack "$dep"
        fi
      done
      ;;
    eks)
      for dep in network backend; do
        if ! stack_has_state "$dep"; then
          echo "==> plan needs $dep state (terraform_remote_state); applying $dep first..."
          if [[ "$dep" == "backend" ]]; then
            for upstream in shared network; do
              if ! stack_has_state "$upstream"; then
                apply_stack "$upstream"
              fi
            done
          fi
          apply_stack "$dep"
        fi
      done
      ;;
  esac
}

if uses_tfc_cloud; then
  if [[ -z "${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}" ]]; then
    echo "TFC cloud backend requires TF_TOKEN_app_terraform_io." >&2
    echo "Or: BACKEND=local $0 $ENV $ACTION" >&2
    exit 1
  fi
  "$ROOT/scripts/ensure-tfc-local-execution.sh"
fi

if uses_s3_backend; then
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"
  export AWS_EC2_METADATA_DISABLED=true
  BUCKET="tfstate-testinfra-${ENV}"
  if ! aws --endpoint-url="${LOCALSTACK_ENDPOINT:-http://localhost:4566}" \
    --region "${AWS_DEFAULT_REGION}" \
    s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo "S3 backend bucket missing ($BUCKET). Run: ./scripts/use-s3-backend.sh $ENV" >&2
    exit 1
  fi
fi

echo "==> Packaging Lambda zip..."
mkdir -p "$ROOT/lambda/api"
(cd "$ROOT/lambda/api" && zip -q -j function.zip handler.py)
if [[ -d "$LIVE/backend/lambda" ]]; then
  cp "$ROOT/lambda/api/function.zip" "$LIVE/backend/lambda/function.zip"
fi

case "$ACTION" in
  apply)
    for stack in "${STACKS[@]}"; do
      apply_stack "$stack"
    done
    echo ""
    echo "==> Outputs ($ENV/backend):"
    terraform -chdir="$LIVE/backend" output || true
    echo ""
    echo "==> Outputs ($ENV/eks):"
    terraform -chdir="$LIVE/eks" output || true
    echo ""
    "$ROOT/scripts/verify-apply.sh" "$ENV"
    ;;
  destroy)
    for ((i=${#STACKS[@]}-1; i>=0; i--)); do
      destroy_stack "${STACKS[$i]}"
    done
    ;;
  plan)
    for stack in "${STACKS[@]}"; do
      ensure_upstream_state_for_plan "$stack"
      plan_stack "$stack"
    done
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    exit 1
    ;;
esac
