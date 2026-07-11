#!/usr/bin/env bash
# Force Terraform Cloud remote state (org ExperimentTerraform by default).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BACKEND=cloud
export TFC_ORG="${1:-${TFC_ORG:-ExperimentTerraform}}"
"$ROOT/scripts/sync-live.sh"
echo "Live stacks now use Terraform Cloud org=${TFC_ORG}."
echo "Export TF_TOKEN_app_terraform_io before terraform init/plan/apply."
echo "Workspaces must use execution_mode=local (see terraform/tfc-bootstrap)."
