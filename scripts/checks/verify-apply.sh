#!/usr/bin/env bash
# Category: checks
# Comprehensive post-apply verification against LocalStack (+ Kind/EKS).
# Usage: verify-apply.sh <dev|staging|production>
# Compatible with Bash 3.2+ (macOS /bin/bash) and Bash 4+/5 (CI).
#
# Supports Terraform backends local | s3 | cloud (detected from live versions.tf,
# or override with BACKEND=). Test bodies live under tests/verify/*.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV="${1:-}"
ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"
KIND_KUBECONFIG="${KIND_KUBECONFIG:-$ROOT/.kube/kind-config}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-testinfra-eks}"
# Consumed by sourced tests/verify/*.sh (same shell); not referenced in this file.
# shellcheck disable=SC2034
LS_CONTAINER="${LOCALSTACK_CONTAINER:-testinfra-localstack}"
# shellcheck disable=SC2034
KIND_DOCKER_NETWORK="${KIND_DOCKER_NETWORK:-kind}"
TESTS_DIR="${VERIFY_TESTS_DIR:-$ROOT/tests/verify}"

PASS=0
FAIL=0

if [[ -z "$ENV" || ! -d "$ROOT/terraform/live/$ENV" ]]; then
  echo "Usage: $0 <dev|staging|production>" >&2
  exit 1
fi

if [[ ! -d "$TESTS_DIR" ]]; then
  echo "Missing tests directory: $TESTS_DIR" >&2
  exit 1
fi

# shellcheck disable=SC2034  # LIVE used by sourced tests/verify/*.sh
LIVE="$ROOT/terraform/live/$ENV"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_EC2_METADATA_DISABLED=true

# Expected naming / CIDR by environment (infra "truths").
# EXPECT_* vars are consumed by sourced tests/verify/*.sh.
# shellcheck disable=SC2034
case "$ENV" in
  staging)
    EXPECT_ENV_SHORT="stg"
    EXPECT_VPC_CIDR="10.1.0.0/16"
    EXPECT_CIDR_PREFIX="10.1"
    EXPECT_LOG_RETENTION="14"
    ;;
  dev)
    EXPECT_ENV_SHORT="dev"
    EXPECT_VPC_CIDR="10.3.0.0/16"
    EXPECT_CIDR_PREFIX="10.3"
    EXPECT_LOG_RETENTION="14"
    ;;
  production)
    EXPECT_ENV_SHORT="prod"
    EXPECT_VPC_CIDR="10.2.0.0/16"
    EXPECT_CIDR_PREFIX="10.2"
    EXPECT_LOG_RETENTION="30"
    ;;
  *)
    echo "Unknown environment: $ENV" >&2
    exit 1
    ;;
esac
EXPECT_PREFIX="testinfra-${EXPECT_ENV_SHORT}"

# shellcheck source=../../tests/verify/lib.sh
# shellcheck disable=SC1091
source "$TESTS_DIR/lib.sh"

require_cmd aws
require_cmd terraform
require_cmd curl
require_cmd python3

echo "======== VERIFY APPLY: $ENV ========"
echo "LocalStack endpoint: $ENDPOINT"
echo "Terraform backend:   $TF_BACKEND"
echo "Region:              $REGION"
echo "Expected prefix:     $EXPECT_PREFIX"
echo "Expected VPC CIDR:   $EXPECT_VPC_CIDR"
echo "Tests dir:           $TESTS_DIR"

# Run numbered test modules in order (sourced so they share PASS/FAIL + outputs).
shopt -s nullglob 2>/dev/null || true
for test_file in "$TESTS_DIR"/[0-9]*.sh; do
  # shellcheck disable=SC1090
  source "$test_file"
done

echo ""
echo "======== VERIFY SUMMARY ($ENV) ========"
echo "Passed:  $PASS"
echo "Failed:  $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Verification FAILED"
  exit 1
fi

echo "Verification PASSED"
exit 0
