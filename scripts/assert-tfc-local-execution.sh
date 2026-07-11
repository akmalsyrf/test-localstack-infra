#!/usr/bin/env bash
# Fail unless every listed workspace has execution-mode exactly "local".
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
    echo "BAD   workspace not found: $name" >&2
    bad=$((bad + 1))
    continue
  fi

  mode="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("execution-mode") or "")')"
  # Strict: only "local" is acceptable. Do not trust legacy operations=false alone.
  if [[ "$mode" == "local" ]]; then
    echo "OK    $name execution-mode=local"
  else
    echo "BAD   $name execution-mode=${mode:-empty} (need local)" >&2
    bad=$((bad + 1))
  fi
done

if [[ "$bad" -gt 0 ]]; then
  echo "" >&2
  echo "Refusing to continue: $bad workspace(s) are not local." >&2
  echo "Run: ./scripts/ensure-tfc-local-execution.sh" >&2
  echo "Or use LocalStack-safe local state:" >&2
  echo "  BACKEND=local ./scripts/sync-live.sh && ./scripts/env.sh <env> apply" >&2
  exit 1
fi
