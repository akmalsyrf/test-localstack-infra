#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:-}"
ACTION="${2:-apply}" # apply | destroy | plan

if [[ -z "$ENV" || ! -d "$ROOT/terraform/live/$ENV" ]]; then
  echo "Usage: $0 <dev|staging> [apply|destroy|plan]" >&2
  exit 1
fi

# Keep live dirs in sync (honors BACKEND / TFC_ORG; default BACKEND=local)
"$ROOT/scripts/sync-live.sh"

LIVE="$ROOT/terraform/live/$ENV"
STACKS=(shared network backend)
APP_NAME="${APP_NAME:-testinfra}"

uses_tfc_cloud() {
  grep -q 'cloud {' "$LIVE/shared/versions.tf" 2>/dev/null
}

if uses_tfc_cloud; then
  if [[ -z "${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}" ]]; then
    echo "TFC cloud backend requires TF_TOKEN_app_terraform_io (or TFE_TOKEN)." >&2
    echo "Or switch to local state: BACKEND=local $0 $ENV $ACTION" >&2
    exit 1
  fi
  echo "==> TFC cloud backend detected — enforcing local execution on all stacks"
  "$ROOT/scripts/ensure-tfc-local-execution.sh"
fi

echo "==> Packaging Lambda zip..."
mkdir -p "$ROOT/lambda/api"
(cd "$ROOT/lambda/api" && zip -q -j function.zip handler.py)
# Refresh vendored zip in backend stack
if [[ -d "$LIVE/backend/lambda" ]]; then
  cp "$ROOT/lambda/api/function.zip" "$LIVE/backend/lambda/function.zip"
fi

run_stack() {
  local stack="$1"
  local dir="$LIVE/$stack"
  local label ws
  label="$(echo "$ACTION" | tr '[:lower:]' '[:upper:]')"
  ws="${APP_NAME}-${stack}-${ENV}"

  echo ""
  echo "======== ${label}: $ENV/$stack ========"

  if uses_tfc_cloud; then
    # Per-stack: force local immediately before this stack runs (backend was still remote before)
    "$ROOT/scripts/force-workspace-local.sh" "$ws"
  fi

  # Drop stale init metadata when switching backends / execution modes
  rm -rf "$dir/.terraform"

  if uses_tfc_cloud; then
    terraform -chdir="$dir" init -input=false
  else
    terraform -chdir="$dir" init -input=false -reconfigure
  fi

  case "$ACTION" in
    apply)   terraform -chdir="$dir" apply -auto-approve -input=false ;;
    destroy) terraform -chdir="$dir" destroy -auto-approve -input=false ;;
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
