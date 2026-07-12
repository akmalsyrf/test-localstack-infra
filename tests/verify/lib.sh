# Shared helpers for verify-apply tests. Sourced by scripts/verify-apply.sh.
# Expects ROOT, ENV, LIVE, ENDPOINT, REGION, and related globals to be set.

detect_tf_backend() {
  if [[ -n "${BACKEND:-}" ]]; then
    case "$BACKEND" in
      local|s3|cloud) echo "$BACKEND"; return ;;
    esac
  fi
  if grep -q 'backend "s3"' "$LIVE/shared/versions.tf" 2>/dev/null; then
    echo s3
  elif grep -q 'cloud {' "$LIVE/shared/versions.tf" 2>/dev/null; then
    echo cloud
  else
    echo local
  fi
}

TF_BACKEND="$(detect_tf_backend)"

aws_ls() {
  aws --endpoint-url="$ENDPOINT" --region "$REGION" "$@"
}

ok() {
  PASS=$((PASS + 1))
  echo "  PASS  $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL  $1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

# Keep S3 backend block endpoints aligned with the working LocalStack URL
# (backend "s3" cannot use variables; Kind attach often breaks localhost on Linux CI).
sync_s3_backend_endpoints() {
  local endpoint="$1"
  local stack vf
  for stack in shared network backend eks; do
    vf="$LIVE/$stack/versions.tf"
    [[ -f "$vf" ]] || continue
    grep -q 'backend "s3"' "$vf" 2>/dev/null || continue
    python3 - "$vf" "$endpoint" <<'PY'
import pathlib, re, sys
path, ep = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
text2, _ = re.subn(r'(?m)^(\s*endpoint\s*=\s*)"[^"]*"', rf'\1"{ep}"', text, count=1)
text3, _ = re.subn(r'(?m)^(\s*dynamodb_endpoint\s*=\s*)"[^"]*"', rf'\1"{ep}"', text2, count=1)
path.write_text(text3)
PY
    tfv="$LIVE/$stack/terraform.tfvars"
    if [[ -f "$tfv" ]]; then
      python3 - "$tfv" "$endpoint" <<'PY'
import pathlib, sys
path, ep = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = []
for line in path.read_text().splitlines(keepends=True):
    if line.lstrip().startswith("localstack_endpoint"):
        lines.append(f'localstack_endpoint    = "{ep}"\n')
    else:
        lines.append(line)
path.write_text("".join(lines))
PY
    fi
  done
}

tf_init_for_outputs() {
  local stack="$1"
  local dir="$LIVE/$stack"
  case "$TF_BACKEND" in
    s3)
      terraform -chdir="$dir" init -input=false -reconfigure -force-copy >/dev/null
      ;;
    cloud)
      terraform -chdir="$dir" init -input=false -reconfigure >/dev/null
      ;;
    local)
      # Local state file is enough; init is cheap if .terraform already exists.
      terraform -chdir="$dir" init -input=false >/dev/null 2>&1 || true
      ;;
  esac
}

ensure_stacks_ready_for_outputs() {
  local stack
  case "$TF_BACKEND" in
    cloud)
      if [[ -z "${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}" ]]; then
        echo "BACKEND=cloud requires TF_TOKEN_app_terraform_io (or TFE_TOKEN)." >&2
        exit 1
      fi
      ;;
    s3)
      sync_s3_backend_endpoints "$ENDPOINT"
      BUCKET="tfstate-testinfra-${ENV}"
      if ! aws_ls s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
        echo "S3 backend bucket missing ($BUCKET). Run: ./scripts/use-s3-backend.sh $ENV" >&2
        exit 1
      fi
      ;;
  esac
  echo "Initializing stacks for outputs (backend=$TF_BACKEND)..."
  for stack in shared network backend eks; do
    if [[ ! -d "$LIVE/$stack" ]]; then
      fail "stack dir missing: $stack"
      continue
    fi
    if ! tf_init_for_outputs "$stack"; then
      fail "terraform init failed for $stack (backend=$TF_BACKEND)"
    else
      ok "terraform init $stack ($TF_BACKEND)"
    fi
  done
}

tf_out() {
  local stack="$1"
  local name="$2"
  terraform -chdir="$LIVE/$stack" output -raw "$name" 2>/dev/null
}

tf_out_json() {
  local stack="$1"
  local name="$2"
  terraform -chdir="$LIVE/$stack" output -json "$name" 2>/dev/null
}

require_out() {
  # require_out <var_name> <stack> <output_name>
  local var_name="$1"
  local stack="$2"
  local name="$3"
  local val
  if val="$(tf_out "$stack" "$name")" && [[ -n "$val" ]]; then
    printf -v "$var_name" '%s' "$val"
    ok "output ${stack}.${name}"
  else
    printf -v "$var_name" '%s' ""
    fail "output ${stack}.${name} missing"
  fi
}

section() {
  echo ""
  echo "==> $1"
}

json_list_len() {
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
}

json_list_lines() {
  python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))'
}
