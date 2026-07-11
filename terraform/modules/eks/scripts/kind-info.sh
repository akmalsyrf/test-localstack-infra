#!/usr/bin/env bash
# Terraform external data source: report Kind cluster facts as JSON.
# stdin: JSON query {kubeconfig, cluster_name, context}
set -euo pipefail

QUERY="$(cat)"
KUBECONFIG_PATH="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("kubeconfig") or "")' <<<"$QUERY")"
CLUSTER_NAME="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("cluster_name") or "testinfra-eks")' <<<"$QUERY")"
CONTEXT="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("context") or "")' <<<"$QUERY")"

# Resolve repo-local ./bin/kind from any vendored depth (live/.../modules/eks/scripts
# or terraform/modules/eks/scripts) by walking parents for bin/kind or kind/cluster.yaml.
find_repo_kind() {
  local dir
  dir="$(cd "$(dirname "$0")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -x "$dir/bin/kind" ]]; then
      echo "$dir/bin/kind"
      return 0
    fi
    if [[ -f "$dir/kind/cluster.yaml" && -x "$dir/bin/kind" ]]; then
      echo "$dir/bin/kind"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

KIND_BIN=""
if [[ -n "${KIND_BIN_OVERRIDE:-}" && -x "${KIND_BIN_OVERRIDE}" ]]; then
  KIND_BIN="$KIND_BIN_OVERRIDE"
elif KIND_BIN="$(find_repo_kind)"; then
  :
elif command -v kind >/dev/null 2>&1; then
  KIND_BIN="$(command -v kind)"
elif [[ -x "$HOME/.local/bin/kind" ]]; then
  KIND_BIN="$HOME/.local/bin/kind"
fi

if [[ -z "$KUBECONFIG_PATH" || ! -f "$KUBECONFIG_PATH" ]]; then
  echo 'kubeconfig missing — run scripts/kind-up.sh' >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo 'kubectl not found' >&2
  exit 1
fi

KC=(--kubeconfig "$KUBECONFIG_PATH")
if [[ -n "$CONTEXT" ]]; then
  KC+=(--context "$CONTEXT")
fi

# Prefer validating via kubectl (always required). kind CLI is optional if the
# cluster is already reachable — Terraform's PATH often omits ./bin.
if ! kubectl "${KC[@]}" cluster-info >/dev/null 2>&1; then
  echo "cannot reach cluster via kubeconfig ($KUBECONFIG_PATH) — run scripts/kind-up.sh" >&2
  exit 1
fi

if [[ -n "$KIND_BIN" ]]; then
  if ! "$KIND_BIN" get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "kind cluster '$CLUSTER_NAME' not found — run scripts/kind-up.sh" >&2
    exit 1
  fi
fi

kubectl "${KC[@]}" wait --for=condition=Ready nodes --all --timeout=60s >/dev/null

ENDPOINT="$(grep -E '^\s*server:' "$KUBECONFIG_PATH" | head -1 | awk '{print $2}')"
VERSION="$(kubectl "${KC[@]}" version -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("serverVersion",{}).get("gitVersion",""))' || true)"
NODE_COUNT="$(kubectl "${KC[@]}" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
READY_COUNT="$(kubectl "${KC[@]}" get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"

python3 -c '
import json,sys
print(json.dumps({
  "endpoint": sys.argv[1],
  "version": sys.argv[2].lstrip("v") or "unknown",
  "node_count": sys.argv[3],
  "ready_count": sys.argv[4],
  "status": "ACTIVE" if int(sys.argv[4]) >= 1 else "CREATING",
  "provider": "kind",
}))
' "${ENDPOINT}" "${VERSION}" "${NODE_COUNT}" "${READY_COUNT}"
