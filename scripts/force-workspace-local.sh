#!/usr/bin/env bash
# Force ONE TFC workspace to execution_mode=local, cancel pending remote runs, verify.
# Usage: force-workspace-local.sh <workspace-name>
set -euo pipefail

NAME="${1:-}"
ORG="${TFC_ORG:-ExperimentTerraform}"
TOKEN="${TF_TOKEN_app_terraform_io:-${TFE_TOKEN:-}}"
API="${TFC_API:-https://app.terraform.io/api/v2}"

if [[ -z "$NAME" ]]; then
  echo "Usage: $0 <workspace-name>" >&2
  exit 1
fi
if [[ -z "$TOKEN" ]]; then
  echo "Set TF_TOKEN_app_terraform_io (or TFE_TOKEN)." >&2
  exit 1
fi

auth=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/vnd.api+json")

api_get() { curl -sS "${auth[@]}" "$1"; }

api_patch() {
  local url="$1" body="$2" tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w "%{http_code}" -X PATCH "${auth[@]}" -d "$body" "$url" || true)"
  if [[ "$code" != 200 && "$code" != 201 ]]; then
    echo "PATCH failed HTTP $code:" >&2
    cat "$tmp" >&2 || true
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

api_post() {
  local url="$1" body="$2" tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "${auth[@]}" -d "$body" "$url" || true)"
  if [[ "$code" != 200 && "$code" != 201 ]]; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

resp="$(api_get "${API}/organizations/${ORG}/workspaces/${NAME}")"
if ! echo "$resp" | python3 -c 'import json,sys; json.load(sys.stdin)["data"]["id"]' >/dev/null 2>&1; then
  echo "Workspace not found: $NAME" >&2
  exit 1
fi

ws_id="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')"
before="$(echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("execution-mode") or "")')"
echo "Workspace $NAME ($ws_id) execution-mode=$before"

# Cancel non-terminal runs so a remote run cannot start mid-apply
runs="$(api_get "${API}/workspaces/${ws_id}/runs?page%5Bsize%5D=20" || true)"
echo "$runs" | python3 -c '
import json,sys,urllib.request,os
token=os.environ.get("TF_TOKEN_app_terraform_io") or os.environ.get("TFE_TOKEN") or ""
api=os.environ.get("TFC_API","https://app.terraform.io/api/v2")
try:
  data=json.load(sys.stdin)
except Exception:
  sys.exit(0)
active={"pending","plan_queued","planning","planned","cost_estimating","cost_estimated","policy_checking","policy_override","policy_checked","confirmed","apply_queued","applying"}
for r in data.get("data") or []:
  st=(r.get("attributes") or {}).get("status") or ""
  rid=r.get("id")
  if st in active and rid:
    print(rid)
' 2>/dev/null | while IFS= read -r rid; do
  [[ -z "$rid" ]] && continue
  echo "  Discarding active run $rid"
  api_post "${API}/runs/${rid}/actions/discard" '{"comment":"localstack-infra: force local execution"}' >/dev/null 2>&1 || \
    api_post "${API}/runs/${rid}/actions/cancel" '{"comment":"localstack-infra: force local execution"}' >/dev/null 2>&1 || true
done

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

body_legacy="$(python3 -c '
import json,sys
print(json.dumps({
  "data": {
    "id": sys.argv[1],
    "type": "workspaces",
    "attributes": {"operations": False}
  }
}))' "$ws_id")"

if ! api_patch "${API}/workspaces/${ws_id}" "$body" >/dev/null; then
  api_patch "${API}/organizations/${ORG}/workspaces/${NAME}" "$body" >/dev/null 2>&1 || \
  api_patch "${API}/workspaces/${ws_id}" "$body_legacy" >/dev/null
fi

# Brief pause for API consistency
sleep 1
verify="$(api_get "${API}/workspaces/${ws_id}")"
after="$(echo "$verify" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("execution-mode") or "")')"
ow="$(echo "$verify" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"].get("setting-overwrites",{}).get("execution-mode"))')"

if [[ "$after" != "local" ]]; then
  echo "FAILED: $NAME still execution-mode=$after (overwrite=$ow)" >&2
  echo "Set UI: https://app.terraform.io/app/${ORG}/workspaces/${NAME}/settings/general" >&2
  echo "  → Execution Mode → Local (custom)" >&2
  echo "Or use local state: BACKEND=local ./scripts/sync-live.sh && ./scripts/env.sh <env> apply" >&2
  exit 1
fi

echo "OK $NAME execution-mode=local (overwrite=$ow)"
