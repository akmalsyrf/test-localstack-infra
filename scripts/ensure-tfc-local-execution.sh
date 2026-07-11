#!/usr/bin/env bash
# Force all testinfra TFC projects + workspaces to execution_mode=local, then verify.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORG="${TFC_ORG:-ExperimentTerraform}"
APP_NAME="${APP_NAME:-testinfra}"
TOKEN="${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}"
API="${TFC_API:-https://app.terraform.io/api/v2}"

if [[ -z "$TOKEN" ]]; then
  echo "Set TF_TOKEN_app_terraform_io (or TFE_TOKEN) first." >&2
  exit 1
fi

auth_hdr=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/vnd.api+json")
api_get() { curl -sS "${auth_hdr[@]}" "$1"; }
api_patch() {
  local url="$1" body="$2" tmp code
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

projects_json="$(api_get "${API}/organizations/${ORG}/projects?page%5Bsize%5D=100")"

echo ""
echo "==> Project defaults → local"
for pname in "${PROJECTS[@]}"; do
  pid="$(echo "$projects_json" | python3 -c '
import json,sys
want=sys.argv[1]
for p in json.load(sys.stdin).get("data") or []:
  if p.get("attributes",{}).get("name")==want:
    print(p["id"]); break
' "$pname" || true)"
  [[ -z "$pid" ]] && echo "  SKIP  $pname" && continue

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
  if api_patch "${API}/projects/${pid}" "$body" >/dev/null; then
    echo "  OK    $pname"
  else
    body2="$(python3 -c '
import json,sys
print(json.dumps({"data":{"type":"projects","id":sys.argv[1],"attributes":{"default-execution-mode":"local"}}}))
' "$pid")"
    api_patch "${API}/projects/${pid}" "$body2" >/dev/null && echo "  OK    $pname (fallback)" || echo "  WARN  $pname"
  fi
done

echo ""
echo "==> Workspaces → local"
fail=0
for name in "${WORKSPACES[@]}"; do
  if ! "$ROOT/scripts/force-workspace-local.sh" "$name"; then
    fail=$((fail + 1))
  fi
done

echo ""
if [[ "$fail" -gt 0 ]]; then
  echo "FAILED: $fail workspace(s) still not local." >&2
  echo "Safe alternative for LocalStack:" >&2
  echo "  BACKEND=local ./scripts/sync-live.sh" >&2
  echo "  ./scripts/env.sh staging apply" >&2
  exit 1
fi

"$ROOT/scripts/assert-tfc-local-execution.sh"
echo "All workspaces verified local."
