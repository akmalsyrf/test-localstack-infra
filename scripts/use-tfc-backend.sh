#!/usr/bin/env bash
# Force Terraform Cloud remote state (org ExperimentTerraform by default).
# Also forces workspace execution_mode=local when a TFC token is available.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BACKEND=cloud
export TFC_ORG="${1:-${TFC_ORG:-ExperimentTerraform}}"
"$ROOT/scripts/sync-live.sh"
echo "Live stacks now use Terraform Cloud org=${TFC_ORG}."

if [[ -n "${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}" ]]; then
  "$ROOT/scripts/ensure-tfc-local-execution.sh"
  "$ROOT/scripts/assert-tfc-local-execution.sh"
  echo "Export TF_TOKEN_app_terraform_io is set; workspaces verified local."
  echo "Use: ./scripts/env.sh staging apply"
else
  echo "Export TF_TOKEN_app_terraform_io then run:"
  echo "  ./scripts/ensure-tfc-local-execution.sh"
  echo "  ./scripts/assert-tfc-local-execution.sh"
  echo "Without local execution you get remote apply + missing ../../../modules."
fi
