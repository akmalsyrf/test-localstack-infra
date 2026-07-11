#!/usr/bin/env bash
# Force testinfra TFC projects + workspaces to execution_mode=local, then verify.
# Without this, terraform plan/apply runs on TFC agents and fails with:
#   Unreadable module directory ../../../modules
#   (and cannot reach LocalStack at localhost:4566)
#
# Usage:
#   export TF_TOKEN_app_terraform_io="..."
#   ./scripts/ensure-tfc-local-execution.sh
set -euo pipefail

ORG="${TFC_ORG:-ExperimentTerraform}"
APP_NAME="${APP_NAME:-testinfra}"
TOKEN="${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}"
API="${TFC_API:-https://app.terraform.io/api/v2}"

if [[ -z "$TOKEN" ]]; then
  echo "Set TF_TOKEN_app_terraform_io (or TFE_TOKEN) first." >&2
  exit 1
fi

auth_hdr=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/vnd.api+json")

api_get() {
  curl -sS "${auth_hdr[@]}" "$1"
}

api_patch() {
  local url="$1"
  local body="$2"
  local tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w "%{http_code}" -X PATCH "${auth_hdr[@]}" -d "$body" "$url" || true)"
  if [[ "$code" != 200 && "$code" != 201 ]]; then
    echo "PATCH $url failed (HTTP $code):" >&2
    cat "$tmp" >&2 || true
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

PROJECTS=(
  "${APP_NAME}-shared"
  "${APP_NAME}-network"
  "${APP_NAME}-backend"
)

WORKSPACES=(
  "${APP_NAME}-shared-dev"
  "${APP_NAME}-shared-staging"
  "${APP_NAME}-network-dev"
  "${APP_NAME}-network-staging"
  "${APP_NAME}-backend-dev"
  "${APP_NAME}-backend-staging"
)

echo "======== TFC local-execution enforce ========"
echo "Org: $ORG"
fail=0

# --- projects: default execution mode = local --------------------------------
echo ""
echo "==> Project defaults → local"

projects_json="$(api_get "${API}/organizations/${ORG}/projects?page%5Bsize%5D=100")"

for pname in "${PROJECTS[@]}"; do
  pid="$(echo "$projects_json" | python3 -c '
import json,sys
want=sys.argv[1]
for p in json.load(sys.stdin).get("data") or []:
  if p.get("attributes",{}).get("name")==want:
    print(p["id"]); break
' "$pname" || true)"

  if [[ -z "$pid" ]]; then
    echo "  SKIP  project $pname not found (run terraform/tfc-bootstrap apply)"
    continue
  fi

  body="$(python3 -c '
import json,sys
print(json.dumps({
  "data": {
    "type": "projects",
    "id": sys.argv[1],
    "attributes": {
      "default-execution-mode": "local",
      "setting-overwrites": {"default-execution-mode": True, "default-agent-pool": True}
    }
  }
}))' "$pid")"

  if out="$(api_patch "${API}/projects/${pid}" "$body")"; then
    mode="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("default-execution-mode",""))' 2>/dev/null || true)"
    echo "  OK    $pname default-execution-mode=${mode:-local}"
  else
    body2="$(python3 -c '
import json,sys
print(json.dumps({
  "data": {
    "type": "projects",
    "id": sys.argv[1],
    "attributes": {"default-execution-mode": "local"}
  }
}))' "$pid")"
    if api_patch "${API}/projects/${pid}" "$body2" >/dev/null; then
      echo "  OK    $pname default-execution-mode=local (fallback)"
    else
      echo "  WARN  could not set project default for $pname"
    fi
  fi
done

# --- workspaces: explicit execution-mode = local -----------------------------
echo ""
echo "==> Workspaces → local (explicit overwrite)"

for name in "${WORKSPACES[@]}"; do
  echo ""
  echo "  -- $name"

  resp="$(api_get "${API}/organizations/${ORG}/workspaces/${name}" || true)"
  if ! echo "$resp" | python3 -c 'import json,sys; json.load(sys.stdin)["data"]["id"]' >/dev/null 2>&1; then
    echo "  SKIP  workspace not found"
    continue
  fi

  ws_id="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')"
  current="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("execution-mode") or "")')"
  echo "  id=$ws_id before: execution-mode=$current"

  body_modern="$(python3 -c '
import json,sys
print(json.dumps({
  "data": {
    "id": sys.argv[1],
    "type": "workspaces",
    "attributes": {
      "execution-mode": "local",
      "setting-overwrites": {"execution-mode": True, "agent-pool": True}
    }
  }
}))' "$ws_id")"

  body_legacy="$(python3 -c '
import json,sys
print(json.dumps({
  "data": {
    "id": sys.argv[1],
    "type": "workspaces",
    "attributes": {"operations": False}
  }
}))' "$ws_id")"

  if ! api_patch "${API}/workspaces/${ws_id}" "$body_modern" >/dev/null; then
    # Fallback: org/name endpoint (some tokens behave differently)
    if ! api_patch "${API}/organizations/${ORG}/workspaces/${name}" "$body_modern" >/dev/null; then
      if ! api_patch "${API}/workspaces/${ws_id}" "$body_legacy" >/dev/null; then
        echo "  FAIL  could not update $name" >&2
        fail=$((fail + 1))
        continue
      fi
      echo "  WARN  used legacy operations=false"
    fi
  fi

  verify="$(api_get "${API}/workspaces/${ws_id}")"
  after="$(echo "$verify" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("execution-mode") or "")')"
  after_ops="$(echo "$verify" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("operations"))')"

  # local mode: execution-mode=local, or legacy operations=false
  if [[ "$after" == "local" ]] || [[ "$after_ops" == "False" || "$after_ops" == "false" ]]; then
    echo "  OK    after: execution-mode=$after operations=$after_ops"
  else
    echo "  FAIL  still not local (execution-mode=$after operations=$after_ops)" >&2
    fail=$((fail + 1))
  fi
done

echo ""
if [[ "$fail" -gt 0 ]]; then
  echo "FAILED: $fail workspace(s) are still remote." >&2
  echo "UI fallback: Workspace → Settings → General → Execution Mode → Local (custom)" >&2
  exit 1
fi

echo "All workspaces verified local."
echo "Re-init stacks with: terraform -chdir=<stack> init -reconfigure"
echo "You must NOT see: \"Preparing the remote apply...\""
