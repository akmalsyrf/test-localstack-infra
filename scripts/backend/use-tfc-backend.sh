#!/usr/bin/env bash
# Category: backend
# Opt in to Terraform Cloud remote state. Prefer local for LocalStack.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export BACKEND=cloud
export TFC_ORG="${1:-${TFC_ORG:-ExperimentTerraform}}"
"$ROOT/scripts/lifecycle/sync-live.sh"
if [[ -z "${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}" ]]; then
  echo "Export TF_TOKEN_app_terraform_io, then re-run." >&2
  exit 1
fi
"$ROOT/scripts/backend/ensure-tfc-local-execution.sh"
echo "Ready: ./scripts/lifecycle/env.sh staging apply"
