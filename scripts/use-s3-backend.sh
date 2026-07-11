#!/usr/bin/env bash
# Opt in to S3 + DynamoDB remote state on LocalStack (free-tier).
# Bootstraps tfstate-<project>-<env> bucket + tflock-<project>-<env> lock table,
# then syncs live stacks with BACKEND=s3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:-staging}"
APP_NAME="${APP_NAME:-testinfra}"
ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"
BOOTSTRAP="$ROOT/terraform/s3-bootstrap"

if [[ ! -d "$ROOT/terraform/live/$ENV" ]]; then
  echo "Usage: $0 <dev|staging>" >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_EC2_METADATA_DISABLED=true

echo "==> Bootstrapping S3 state backend for $ENV (LocalStack)..."
cat > "$BOOTSTRAP/terraform.tfvars" <<EOF
project_name         = "${APP_NAME}"
environment_slug     = "${ENV}"
aws_region           = "${REGION}"
localstack_endpoint  = "${ENDPOINT}"
EOF

terraform -chdir="$BOOTSTRAP" init -input=false
terraform -chdir="$BOOTSTRAP" apply -auto-approve -input=false

export BACKEND=s3
export APP_NAME
export LOCALSTACK_ENDPOINT="$ENDPOINT"
"$ROOT/scripts/sync-live.sh"

echo "Ready: BACKEND=s3 ./scripts/env.sh $ENV apply"
echo "State bucket: tfstate-${APP_NAME}-${ENV}"
echo "Lock table:   tflock-${APP_NAME}-${ENV}"
