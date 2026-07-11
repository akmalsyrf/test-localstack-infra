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
STACKS=(shared network backend)

uses_tfc_cloud() {
  grep -q 'cloud {' "$LIVE/shared/versions.tf" 2>/dev/null
}

if uses_tfc_cloud; then
  if [[ -z "${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}" ]]; then
    echo "TFC cloud backend requires TF_TOKEN_app_terraform_io." >&2
    echo "Or: BACKEND=local $0 $ENV $ACTION" >&2
    exit 1
  fi
  "$ROOT/scripts/ensure-tfc-local-execution.sh"
fi

echo "==> Packaging Lambda zip..."
mkdir -p "$ROOT/lambda/api"
(cd "$ROOT/lambda/api" && zip -q -j function.zip handler.py)
if [[ -d "$LIVE/backend/lambda" ]]; then
  cp "$ROOT/lambda/api/function.zip" "$LIVE/backend/lambda/function.zip"
fi

run_stack() {
  local stack="$1"
  local dir="$LIVE/$stack"
  local label parallelism=10
  label="$(echo "$ACTION" | tr '[:lower:]' '[:upper:]')"

  echo ""
  echo "======== ${label}: $ENV/$stack ========"

  terraform -chdir="$dir" init -input=false

  # Backend messaging (SNS/SQS) must stay serial on LocalStack
  if [[ "$stack" == "backend" ]]; then
    parallelism=1
  fi

  case "$ACTION" in
    apply)   terraform -chdir="$dir" apply -auto-approve -input=false -parallelism="$parallelism" ;;
    destroy) terraform -chdir="$dir" destroy -auto-approve -input=false -parallelism="$parallelism" ;;
    plan)    terraform -chdir="$dir" plan -input=false ;;
    *) echo "Unknown action: $ACTION" >&2; exit 1 ;;
  esac
}

if [[ "$ACTION" == "destroy" ]]; then
  for ((i=${#STACKS[@]}-1; i>=0; i--)); do
    run_stack "${STACKS[$i]}"
  done
else
  for stack in "${STACKS[@]}"; do
    run_stack "$stack"
  done
fi

if [[ "$ACTION" == "apply" ]]; then
  echo ""
  echo "==> Outputs ($ENV/backend):"
  terraform -chdir="$LIVE/backend" output || true
  echo ""
  "$ROOT/scripts/verify-apply.sh" "$ENV"
fi
