#!/usr/bin/env bash
# Opt in to Terraform Cloud remote state (org ExperimentTerraform by default).
# WARNING: every workspace MUST use execution_mode=local or apply runs on TFC
# agents and fails (missing modules / cannot reach LocalStack).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BACKEND=cloud
export TFC_ORG="${1:-${TFC_ORG:-ExperimentTerraform}}"
"$ROOT/scripts/sync-live.sh"
echo "Live stacks now use Terraform Cloud org=${TFC_ORG}."

if [[ -n "${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}" ]]; then
  "$ROOT/scripts/ensure-tfc-local-execution.sh"
  echo "Use: ./scripts/env.sh staging apply"
  echo "Prefer local state for LocalStack: ./scripts/use-local-backend.sh"
else
  echo "Export TF_TOKEN_app_terraform_io then re-run this script."
  echo "Or use: ./scripts/use-local-backend.sh"
fi
