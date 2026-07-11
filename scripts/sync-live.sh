#!/usr/bin/env bash
# Sync _templates → live/{dev,staging}/{shared,network,backend,eks}
#
# BACKEND=local (default) → local terraform.tfstate (recommended for LocalStack)
# BACKEND=s3              → S3 + DynamoDB remote state on LocalStack
#                           (run ./scripts/use-s3-backend.sh first to bootstrap)
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
AWS_REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"
LOCALSTACK_ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"

vendor_modules() {
  local dest="$1"
  local main="$dest/main.tf"
  rm -rf "$dest/modules"
  mkdir -p "$dest/modules"
  # Copy modules referenced by this stack's main.tf, then nested relative modules
  # (e.g. modules/eks → ../iam-eks-workload).
  local name nested
  for name in $(grep -E 'source\s*=\s*"(\.\./)+modules/[^"]+"' "$main" \
    | sed -E 's|.*modules/([^"]+)".*|\1|' | sort -u); do
    if [[ -d "$MODULES/$name" ]]; then
      cp -R "$MODULES/$name" "$dest/modules/$name"
      find "$dest/modules/$name" -type f -name '*.sh' -exec chmod +x {} \;
    else
      echo "Missing module: $MODULES/$name" >&2
      exit 1
    fi
    # Nested: source = "../other-module" inside vendored *.tf only
    while IFS= read -r nested; do
      [[ -z "$nested" ]] && continue
      if [[ -d "$MODULES/$nested" ]]; then
        if [[ ! -d "$dest/modules/$nested" ]]; then
          cp -R "$MODULES/$nested" "$dest/modules/$nested"
          find "$dest/modules/$nested" -type f -name '*.sh' -exec chmod +x {} \;
        fi
      else
        echo "Missing nested module: $MODULES/$nested (from $name)" >&2
        exit 1
      fi
    done < <(find "$dest/modules/$name" -type f -name '*.tf' -print0 \
      | xargs -0 grep -hE 'source[[:space:]]*=[[:space:]]*"\.\./[A-Za-z0-9_-]+"' 2>/dev/null \
      | sed -E 's/.*"\.\.\/([A-Za-z0-9_-]+)".*/\1/' \
      | sort -u)
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

render_s3_versions() {
  local src="$1"
  local dest="$2"
  local env="$3"
  local project="$4"
  local bucket="tfstate-${APP_NAME}-${env}"
  local table="tflock-${APP_NAME}-${env}"
  local key="${project}/terraform.tfstate"

  sed \
    -e "s|__TFSTATE_BUCKET__|${bucket}|g" \
    -e "s|__TFLOCK_TABLE__|${table}|g" \
    -e "s|__TFSTATE_KEY__|${key}|g" \
    -e "s|__AWS_REGION__|${AWS_REGION}|g" \
    -e "s|__LOCALSTACK_ENDPOINT__|${LOCALSTACK_ENDPOINT}|g" \
    "$src" > "$dest"
}

render_s3_main() {
  local src="$1"
  local dest="$2"
  local env="$3"
  local bucket="tfstate-${APP_NAME}-${env}"

  sed \
    -e "s|__TFSTATE_BUCKET__|${bucket}|g" \
    -e "s|__AWS_REGION__|${AWS_REGION}|g" \
    -e "s|__LOCALSTACK_ENDPOINT__|${LOCALSTACK_ENDPOINT}|g" \
    "$src" > "$dest"
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
  elif [[ "$BACKEND" == "s3" ]]; then
    if [[ "$project" == "backend" || "$project" == "eks" ]]; then
      render_s3_versions "$TPL/$project/versions.s3.tf" "$dest/versions.tf" "$env" "$project"
      render_s3_main "$TPL/$project/main.s3.tf" "$dest/main.tf" "$env"
    else
      render_s3_versions "$TPL/_common/versions.s3.tf" "$dest/versions.tf" "$env" "$project"
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
aws_region             = "${AWS_REGION}"
localstack_endpoint    = "${LOCALSTACK_ENDPOINT}"
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

case "$BACKEND" in
  local|s3|cloud) ;;
  *)
    echo "Unknown BACKEND=$BACKEND (expected local|s3|cloud)" >&2
    exit 1
    ;;
esac

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
if [[ "$BACKEND" == "s3" ]]; then
  echo "NOTE: Ensure s3-bootstrap applied (./scripts/use-s3-backend.sh <env>) before first init."
fi
