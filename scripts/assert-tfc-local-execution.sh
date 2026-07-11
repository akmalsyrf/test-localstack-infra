#!/usr/bin/env bash
# Fail fast if any testinfra TFC workspace is still on remote execution.
# Usage: ./scripts/assert-tfc-local-execution.sh [workspace-name ...]
set -euo pipefail

ORG="${TFC_ORG:-ExperimentTerraform}"
APP_NAME="${APP_NAME:-testinfra}"
TOKEN="${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}"
API="${TFC_API:-https://app.terraform.io/api/v2}"

if [[ -z "$TOKEN" ]]; then
  echo "Set TF_TOKEN_app_terraform_io (or TFE_TOKEN) first." >&2
  exit 1
fi

if [[ "$#" -gt 0 ]]; then
  WORKSPACES=("$@")
else
  WORKSPACES=(
    "${APP_NAME}-shared-dev"
    "${APP_NAME}-shared-staging"
    "${APP_NAME}-network-dev"
    "${APP_NAME}-network-staging"
    "${APP_NAME}-backend-dev"
    "${APP_NAME}-backend-staging"
  )
fi

bad=0
for name in "${WORKSPACES[@]}"; do
  resp="$(curl -sS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/vnd.api+json" \
    "${API}/organizations/${ORG}/workspaces/${name}" || true)"

  if ! echo "$resp" | python3 -c 'import json,sys; json.load(sys.stdin)["data"]["id"]' >/dev/null 2>&1; then
    echo "WARN  workspace not found: $name"
    continue
  fi

  mode="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("execution-mode") or "")')"
  ops="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("operations"))')"

  if [[ "$mode" == "local" ]] || [[ "$ops" == "False" || "$ops" == "false" ]]; then
    echo "OK    $name execution-mode=$mode"
  else
    echo "BAD   $name execution-mode=$mode (need local)" >&2
    bad=$((bad + 1))
  fi
done

if [[ "$bad" -gt 0 ]]; then
  echo "" >&2
  echo "Refusing to continue: $bad workspace(s) still use remote execution." >&2
  echo "Run: ./scripts/ensure-tfc-local-execution.sh" >&2
  echo "Then: terraform -chdir=<stack> init -reconfigure" >&2
  exit 1
fi
