#!/usr/bin/env bash
# Sync _templates → live/{dev,staging}/{shared,network,backend,eks}
#
# BACKEND=local (default) → local terraform.tfstate (recommended for LocalStack)
# BACKEND=cloud           → Terraform Cloud remote state (org ExperimentTerraform)
#                           Requires workspace execution_mode=local or apply fails.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$ROOT/terraform/live/_templates"
LIVE="$ROOT/terraform/live"
MODULES="$ROOT/terraform/modules"
BACKEND="${BACKEND:-local}"
TFC_ORG="${TFC_ORG:-ExperimentTerraform}"
APP_NAME="${APP_NAME:-testinfra}"
PROJECTS=(shared network backend eks)
KIND_KUBECONFIG="${KIND_KUBECONFIG:-$ROOT/.kube/kind-config}"
KIND_CONTEXT="${KIND_CONTEXT:-kind-testinfra-eks}"

vendor_modules() {
  local dest="$1"
  local main="$dest/main.tf"
  rm -rf "$dest/modules"
  mkdir -p "$dest/modules"
  # Copy only modules referenced by this stack's main.tf
  local name
  for name in $(grep -E 'source\s*=\s*"(\.\./)+modules/[^"]+"' "$main" \
    | sed -E 's|.*modules/([^"]+)".*|\1|' | sort -u); do
    if [[ -d "$MODULES/$name" ]]; then
      cp -R "$MODULES/$name" "$dest/modules/$name"
      # Preserve executable helpers (e.g. eks/scripts/kind-info.sh)
      find "$dest/modules/$name" -type f -name '*.sh' -exec chmod +x {} \;
    else
      echo "Missing module: $MODULES/$name" >&2
      exit 1
    fi
  done
  # Rewrite ../../../modules/X → ./modules/X (self-contained stack dir)
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' -E 's|source = "(\.\./)+modules/|source = "./modules/|g' "$main"
  else
    sed -i -E 's|source = "(\.\./)+modules/|source = "./modules/|g' "$main"
  fi
}

stage_lambda_zip() {
  local dest="$1"
  mkdir -p "$dest/lambda" "$ROOT/lambda/api"
  if [[ ! -f "$ROOT/lambda/api/function.zip" ]]; then
    (cd "$ROOT/lambda/api" && zip -q -j function.zip handler.py)
  fi
  cp "$ROOT/lambda/api/function.zip" "$dest/lambda/function.zip"
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' 's|lambda_zip_path = "${path.module}/../../../../lambda/api/function.zip"|lambda_zip_path = "${path.module}/lambda/function.zip"|g' "$dest/main.tf"
  else
    sed -i 's|lambda_zip_path = "${path.module}/../../../../lambda/api/function.zip"|lambda_zip_path = "${path.module}/lambda/function.zip"|g' "$dest/main.tf"
  fi
}

sync_project() {
  local env="$1"
  local project="$2"
  local dest="$LIVE/$env/$project"
  local workspace="${APP_NAME}-${project}-${env}"
  mkdir -p "$dest"

  cp "$TPL/_common/variables.tf" "$dest/variables.tf"

  if [[ "$BACKEND" == "cloud" ]]; then
    if [[ "$project" == "backend" || "$project" == "eks" ]]; then
      sed "s/__TFC_WORKSPACE__/${workspace}/g" "$TPL/$project/versions.tf" > "$dest/versions.tf"
      cp "$TPL/$project/main.tf" "$dest/main.tf"
    else
      sed "s/__TFC_WORKSPACE__/${workspace}/g" "$TPL/_common/versions.tf" > "$dest/versions.tf"
      cp "$TPL/$project/main.tf" "$dest/main.tf"
    fi
  else
    if [[ "$project" == "backend" || "$project" == "eks" ]]; then
      cp "$TPL/$project/versions.local.tf" "$dest/versions.tf"
      cp "$TPL/$project/main.local.tf" "$dest/main.tf"
    else
      cp "$TPL/_common/versions.local.tf" "$dest/versions.tf"
      cp "$TPL/$project/main.tf" "$dest/main.tf"
    fi
  fi

  if [[ "$project" == "network" ]]; then
    cat >> "$dest/variables.tf" <<'EOF'

variable "vpc_cidr_prefix" {
  type        = string
  description = "First two octets for VPC CIDR, e.g. 10.3 (dev) or 10.1 (staging)"
}
EOF
  fi

  vendor_modules "$dest"

  if [[ "$project" == "backend" ]]; then
    stage_lambda_zip "$dest"
  fi
}

write_tfvars() {
  local env="$1"
  local short="$2"
  local cidr="$3"
  local tfc_org=""

  if [[ "$BACKEND" == "cloud" ]]; then
    tfc_org="$TFC_ORG"
  fi

  for project in "${PROJECTS[@]}"; do
    cat > "$LIVE/$env/$project/terraform.tfvars" <<EOF
project_name           = "${APP_NAME}"
environment            = "$short"
environment_slug       = "$env"
aws_region             = "ap-southeast-3"
localstack_endpoint    = "http://localhost:4566"
tfc_organization       = "${tfc_org}"
kind_kubeconfig_path   = "${KIND_KUBECONFIG}"
kind_context           = "${KIND_CONTEXT}"
EOF
    if [[ "$project" == "network" ]]; then
      echo "vpc_cidr_prefix = \"$cidr\"" >> "$LIVE/$env/$project/terraform.tfvars"
    fi

    cp "$LIVE/$env/$project/terraform.tfvars" "$LIVE/$env/$project/terraform.tfvars.example"
  done
}

for env in dev staging; do
  for project in "${PROJECTS[@]}"; do
    sync_project "$env" "$project"
  done
done

write_tfvars "dev" "dev" "10.3"
write_tfvars "staging" "stg" "10.1"

echo "Synced templates → live/{dev,staging}/{shared,network,backend,eks} (BACKEND=${BACKEND}, TFC_ORG=${TFC_ORG})"
if [[ "$BACKEND" == "cloud" ]]; then
  echo "NOTE: TFC workspaces MUST use execution_mode=local. Run: ./scripts/ensure-tfc-local-execution.sh"
fi
