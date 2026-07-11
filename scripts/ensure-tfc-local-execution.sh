#!/usr/bin/env bash
# Force all testinfra TFC workspaces (+ project defaults) to execution_mode=local.
set -euo pipefail

ORG="${TFC_ORG:-ExperimentTerraform}"
APP_NAME="${APP_NAME:-testinfra}"
TOKEN="${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}"
API="${TFC_API:-https://app.terraform.io/api/v2}"

if [[ -z "$TOKEN" ]]; then
  echo "Set TF_TOKEN_app_terraform_io (or TFE_TOKEN) first." >&2
  exit 1
fi

auth=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/vnd.api+json")

api_get() { curl -sS "${auth[@]}" "$1"; }

api_patch() {
  local url="$1" body="$2" tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w "%{http_code}" -X PATCH "${auth[@]}" -d "$body" "$url" || true)"
  if [[ "$code" != 200 && "$code" != 201 ]]; then
    echo "PATCH $url failed (HTTP $code):" >&2
    cat "$tmp" >&2 || true
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

force_workspace_local() {
  local name="$1"
  local resp ws_id before after body

  resp="$(api_get "${API}/organizations/${ORG}/workspaces/${name}" || true)"
  if ! echo "$resp" | python3 -c 'import json,sys; json.load(sys.stdin)["data"]["id"]' >/dev/null 2>&1; then
    echo "  SKIP  $name (not found)"
    return 0
  fi

  ws_id="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')"
  before="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("execution-mode") or "")')"

  body="$(python3 -c '
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

  api_patch "${API}/workspaces/${ws_id}" "$body" >/dev/null || \
    api_patch "${API}/organizations/${ORG}/workspaces/${name}" "$body" >/dev/null || return 1

  sleep 1
  after="$(api_get "${API}/workspaces/${ws_id}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("execution-mode") or "")')"
  if [[ "$after" != "local" ]]; then
    echo "  FAIL  $name still execution-mode=$after (was $before)" >&2
    return 1
  fi
  echo "  OK    $name execution-mode=local"
}

echo "======== TFC local-execution enforce (org=$ORG) ========"

projects_json="$(api_get "${API}/organizations/${ORG}/projects?page%5Bsize%5D=100")"
for pname in "${APP_NAME}-shared" "${APP_NAME}-network" "${APP_NAME}-backend" "${APP_NAME}-eks"; do
  pid="$(echo "$projects_json" | python3 -c '
import json,sys
want=sys.argv[1]
for p in json.load(sys.stdin).get("data") or []:
  if p.get("attributes",{}).get("name")==want:
    print(p["id"]); break
' "$pname" || true)"
  [[ -z "$pid" ]] && continue
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
  api_patch "${API}/projects/${pid}" "$body" >/dev/null 2>&1 || true
done

fail=0
for name in \
  "${APP_NAME}-shared-dev" "${APP_NAME}-shared-staging" \
  "${APP_NAME}-network-dev" "${APP_NAME}-network-staging" \
  "${APP_NAME}-backend-dev" "${APP_NAME}-backend-staging" \
  "${APP_NAME}-eks-dev" "${APP_NAME}-eks-staging"
do
  force_workspace_local "$name" || fail=$((fail + 1))
done

if [[ "$fail" -gt 0 ]]; then
  echo "FAILED: $fail workspace(s) not local. Use BACKEND=local instead." >&2
  exit 1
fi
echo "All workspaces are local."
