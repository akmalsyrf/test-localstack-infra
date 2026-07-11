#!/usr/bin/env bash
# Sync _templates → live/{dev,staging}/{shared,network,backend}
#
# BACKEND=cloud (default) → Terraform Cloud remote state (org ExperimentTerraform)
# BACKEND=local            → local terraform.tfstate files
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$ROOT/terraform/live/_templates"
LIVE="$ROOT/terraform/live"
BACKEND="${BACKEND:-cloud}"
TFC_ORG="${TFC_ORG:-ExperimentTerraform}"
APP_NAME="${APP_NAME:-testinfra}"

sync_project() {
  local env="$1"
  local project="$2"
  local dest="$LIVE/$env/$project"
  local workspace="${APP_NAME}-${project}-${env}"
  mkdir -p "$dest"

  cp "$TPL/_common/variables.tf" "$dest/variables.tf"

  if [[ "$BACKEND" == "local" ]]; then
    if [[ "$project" == "backend" ]]; then
      cp "$TPL/backend/versions.local.tf" "$dest/versions.tf"
      cp "$TPL/backend/main.tf" "$dest/main.tf"
    else
      cp "$TPL/_common/versions.local.tf" "$dest/versions.tf"
      cp "$TPL/$project/main.tf" "$dest/main.tf"
    fi
  else
    if [[ "$project" == "backend" ]]; then
      sed "s/__TFC_WORKSPACE__/${workspace}/g" "$TPL/backend/versions.tf" > "$dest/versions.tf"
      cp "$TPL/backend/main.tf" "$dest/main.tf"
    else
      sed "s/__TFC_WORKSPACE__/${workspace}/g" "$TPL/_common/versions.tf" > "$dest/versions.tf"
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
}

write_tfvars() {
  local env="$1"
  local short="$2"
  local cidr="$3"
  local tfc_org=""

  if [[ "$BACKEND" == "cloud" ]]; then
    tfc_org="$TFC_ORG"
  fi

  for project in shared network backend; do
    cat > "$LIVE/$env/$project/terraform.tfvars" <<EOF
project_name        = "${APP_NAME}"
environment         = "$short"
environment_slug    = "$env"
aws_region          = "ap-southeast-3"
localstack_endpoint = "http://localhost:4566"
tfc_organization    = "${tfc_org}"
EOF
    if [[ "$project" == "network" ]]; then
      echo "vpc_cidr_prefix = \"$cidr\"" >> "$LIVE/$env/$project/terraform.tfvars"
    fi

    # Commit-friendly example (tfvars themselves are gitignored)
    cp "$LIVE/$env/$project/terraform.tfvars" "$LIVE/$env/$project/terraform.tfvars.example"
  done
}

for env in dev staging; do
  for project in shared network backend; do
    sync_project "$env" "$project"
  done
done

write_tfvars "dev" "dev" "10.3"
write_tfvars "staging" "stg" "10.1"

echo "Synced templates → live/{dev,staging}/{shared,network,backend} (BACKEND=${BACKEND}, TFC_ORG=${TFC_ORG})"
