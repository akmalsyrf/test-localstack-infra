#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:-}"
ACTION="${2:-apply}" # apply | destroy | plan
# Optional comma-separated stack filter, e.g. shared,network,backend or eks.
# Default: all stacks in order. Used by CI to apply Kind-independent stacks
# before Kind starts (see .github/workflows/terraform.yml).
STACK_FILTER="${3:-}"

if [[ -z "$ENV" || ! -d "$ROOT/terraform/live/$ENV" ]]; then
  echo "Usage: $0 <dev|staging|production> [apply|destroy|plan] [stack1,stack2,...]" >&2
  exit 1
fi

"$ROOT/scripts/sync-live.sh"

LIVE="$ROOT/terraform/live/$ENV"
# Apply order: shared → network → backend → eks (EKS needs VPC/subnets + Kind)
ALL_STACKS=(shared network backend eks)

filter_stacks() {
  local filter="$1"
  local s f
  local -a out=()
  if [[ -z "$filter" ]]; then
    STACKS=("${ALL_STACKS[@]}")
    return
  fi
  IFS=',' read -r -a wanted <<< "$filter"
  for s in "${ALL_STACKS[@]}"; do
    for f in "${wanted[@]}"; do
      f="$(echo "$f" | tr -d '[:space:]')"
      if [[ "$s" == "$f" ]]; then
        out+=("$s")
        break
      fi
    done
  done
  if [[ "${#out[@]}" -eq 0 ]]; then
    echo "No valid stacks in filter '$filter' (allowed: ${ALL_STACKS[*]})" >&2
    exit 1
  fi
  STACKS=("${out[@]}")
}

filter_stacks "$STACK_FILTER"
echo "==> Stacks: ${STACKS[*]}"

LS_CONTAINER="${LOCALSTACK_CONTAINER:-testinfra-localstack}"
KIND_DOCKER_NETWORK="${KIND_DOCKER_NETWORK:-kind}"

includes_stack() {
  local needle="$1"
  local s
  for s in "${STACKS[@]}"; do
    [[ "$s" == "$needle" ]] && return 0
  done
  return 1
}

# On Linux CI, attaching LocalStack to the Kind network often breaks host :4566
# publish. Prefer localhost when it works; otherwise talk to the container IP
# on a non-kind Docker network (reachable from the GitHub runner host).
ensure_localstack_endpoint() {
  local preferred="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
  local ip="" endpoint=""

  if curl -sf --max-time 3 "${preferred}/_localstack/health" >/dev/null 2>&1; then
    endpoint="$preferred"
  elif docker inspect "$LS_CONTAINER" >/dev/null 2>&1; then
    ip="$(docker inspect -f '{{range $n,$c := .NetworkSettings.Networks}}{{if ne $n "kind"}}{{println $c.IPAddress}}{{end}}{{end}}' "$LS_CONTAINER" 2>/dev/null | awk 'NF{print; exit}')"
    if [[ -z "$ip" ]]; then
      ip="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${KIND_DOCKER_NETWORK}\").IPAddress }}" "$LS_CONTAINER" 2>/dev/null || true)"
    fi
    if [[ -n "$ip" && "$ip" != "<no value>" ]]; then
      endpoint="http://${ip}:4566"
      if ! curl -sf --max-time 3 "${endpoint}/_localstack/health" >/dev/null 2>&1; then
        endpoint=""
      fi
    fi
  fi

  if [[ -z "$endpoint" ]]; then
    echo "LocalStack unreachable (tried $preferred and container IP)." >&2
    docker compose ps 2>/dev/null || true
    exit 1
  fi

  export LOCALSTACK_ENDPOINT="$endpoint"
  export TF_VAR_localstack_endpoint="$endpoint"
  if [[ "$endpoint" != "http://localhost:4566" && "$endpoint" != "http://127.0.0.1:4566" ]]; then
    echo "==> Host :4566 publish broken; using container IP for Terraform: $endpoint"
  else
    echo "==> LocalStack endpoint: $endpoint"
  fi
  # Keep terraform.tfvars in sync: it overrides TF_VAR_ and is written by sync-live
  # with localhost before Kind attach can break host publish on Linux CI.
  if [[ -d "$LIVE" ]]; then
    local tfv stack
    for stack in "${ALL_STACKS[@]}"; do
      tfv="$LIVE/$stack/terraform.tfvars"
      if [[ -f "$tfv" ]]; then
        python3 - "$tfv" "$endpoint" <<'PY'
import pathlib, sys
path, ep = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
lines = []
for line in text.splitlines(keepends=True):
    if line.lstrip().startswith("localstack_endpoint"):
        lines.append(f'localstack_endpoint    = "{ep}"\n')
    else:
        lines.append(line)
path.write_text("".join(lines))
PY
      fi
    done
  fi
  # Persist for later CI steps (verify-apply, latency checks).
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      echo "LOCALSTACK_ENDPOINT=$endpoint"
      echo "TF_VAR_localstack_endpoint=$endpoint"
    } >> "$GITHUB_ENV"
  fi
}

# Attach LocalStack to Kind *before* terraform apply so data.external does not
# race IAM creates and break localhost mid-apply on Linux CI.
prepare_kind_localstack_bridge() {
  if ! includes_stack eks; then
    return 0
  fi
  if ! docker network inspect "$KIND_DOCKER_NETWORK" >/dev/null 2>&1; then
    echo "WARNING: Docker network '$KIND_DOCKER_NETWORK' missing — start Kind before eks." >&2
    return 0
  fi
  echo "==> Ensuring $LS_CONTAINER on Docker network '$KIND_DOCKER_NETWORK' (before eks)..."
  docker network connect "$KIND_DOCKER_NETWORK" "$LS_CONTAINER" 2>/dev/null || true
  ensure_localstack_endpoint
}

uses_tfc_cloud() {
  grep -q 'cloud {' "$LIVE/shared/versions.tf" 2>/dev/null
}

uses_s3_backend() {
  grep -q 'backend "s3"' "$LIVE/shared/versions.tf" 2>/dev/null
}

stack_has_state() {
  local stack="$1"
  if uses_s3_backend || uses_tfc_cloud; then
    # Remote backends: probe via outputs after init (no local terraform.tfstate).
    terraform -chdir="$LIVE/$stack" init -input=false >/dev/null 2>&1 || return 1
    terraform -chdir="$LIVE/$stack" output -json >/dev/null 2>&1
    return $?
  fi
  local state="$LIVE/$stack/terraform.tfstate"
  [[ -f "$state" ]] || return 1
  # Empty / never-applied local state still "exists" as a file sometimes; require outputs.
  terraform -chdir="$LIVE/$stack" output -json >/dev/null 2>&1
}

apply_stack() {
  local stack="$1"
  local dir="$LIVE/$stack"
  local parallelism=10

  echo ""
  echo "======== APPLY: $ENV/$stack ========"
  echo "    localstack_endpoint=$LOCALSTACK_ENDPOINT"
  terraform -chdir="$dir" init -input=false

  # LocalStack + Kind on small CI runners: serialize chatty stacks.
  if [[ "$stack" == "backend" || "$stack" == "eks" ]]; then
    parallelism=1
  fi
  # -var beats terraform.tfvars (sync-live bakes localhost before kind-attach).
  terraform -chdir="$dir" apply -auto-approve -input=false -parallelism="$parallelism" \
    -var="localstack_endpoint=${LOCALSTACK_ENDPOINT}"
}

plan_stack() {
  local stack="$1"
  local dir="$LIVE/$stack"

  echo ""
  echo "======== PLAN: $ENV/$stack ========"
  echo "    localstack_endpoint=$LOCALSTACK_ENDPOINT"
  terraform -chdir="$dir" init -input=false
  terraform -chdir="$dir" plan -input=false \
    -var="localstack_endpoint=${LOCALSTACK_ENDPOINT}"
}

destroy_stack() {
  local stack="$1"
  local dir="$LIVE/$stack"
  local parallelism=10

  echo ""
  echo "======== DESTROY: $ENV/$stack ========"
  echo "    localstack_endpoint=$LOCALSTACK_ENDPOINT"
  terraform -chdir="$dir" init -input=false

  if [[ "$stack" == "backend" || "$stack" == "eks" ]]; then
    parallelism=1
  fi
  terraform -chdir="$dir" destroy -auto-approve -input=false -parallelism="$parallelism" \
    -var="localstack_endpoint=${LOCALSTACK_ENDPOINT}"
}

# Local backend: dependent stacks read sibling terraform.tfstate via
# terraform_remote_state. Ephemeral CI (and fresh checkouts) have no state until
# apply — so plan must apply upstream stacks first.
ensure_upstream_state_for_plan() {
  local stack="$1"
  case "$stack" in
    backend)
      for dep in shared network; do
        if ! stack_has_state "$dep"; then
          echo "==> plan needs $dep state (terraform_remote_state); applying $dep first..."
          apply_stack "$dep"
        fi
      done
      ;;
    eks)
      for dep in network backend; do
        if ! stack_has_state "$dep"; then
          echo "==> plan needs $dep state (terraform_remote_state); applying $dep first..."
          if [[ "$dep" == "backend" ]]; then
            for upstream in shared network; do
              if ! stack_has_state "$upstream"; then
                apply_stack "$upstream"
              fi
            done
          fi
          apply_stack "$dep"
        fi
      done
      ;;
  esac
}

if uses_tfc_cloud; then
  if [[ -z "${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}" ]]; then
    echo "TFC cloud backend requires TF_TOKEN_app_terraform_io." >&2
    echo "Or: BACKEND=local $0 $ENV $ACTION" >&2
    exit 1
  fi
  "$ROOT/scripts/ensure-tfc-local-execution.sh"
fi

ensure_localstack_endpoint
prepare_kind_localstack_bridge

if uses_s3_backend; then
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"
  export AWS_EC2_METADATA_DISABLED=true
  BUCKET="tfstate-testinfra-${ENV}"
  if ! aws --endpoint-url="${LOCALSTACK_ENDPOINT}" \
    --region "${AWS_DEFAULT_REGION}" \
    s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo "S3 backend bucket missing ($BUCKET). Run: ./scripts/use-s3-backend.sh $ENV" >&2
    exit 1
  fi
fi

echo "==> Packaging Lambda zip..."
mkdir -p "$ROOT/lambda/api"
(cd "$ROOT/lambda/api" && zip -q -j function.zip handler.py)
if [[ -d "$LIVE/backend/lambda" ]]; then
  cp "$ROOT/lambda/api/function.zip" "$LIVE/backend/lambda/function.zip"
fi

case "$ACTION" in
  apply)
    for stack in "${STACKS[@]}"; do
      apply_stack "$stack"
    done
    if includes_stack backend; then
      echo ""
      echo "==> Outputs ($ENV/backend):"
      terraform -chdir="$LIVE/backend" output || true
    fi
    if includes_stack eks; then
      echo ""
      echo "==> Outputs ($ENV/eks):"
      terraform -chdir="$LIVE/eks" output || true
    fi
    # Full verify only when the default all-stacks path ran (local convenience).
    # CI runs verify as a separate step after Kind + eks.
    if [[ -z "$STACK_FILTER" ]]; then
      echo ""
      "$ROOT/scripts/verify-apply.sh" "$ENV"
    fi
    ;;
  destroy)
    for ((i=${#STACKS[@]}-1; i>=0; i--)); do
      destroy_stack "${STACKS[$i]}"
    done
    ;;
  plan)
    for stack in "${STACKS[@]}"; do
      ensure_upstream_state_for_plan "$stack"
      plan_stack "$stack"
    done
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    exit 1
    ;;
esac
