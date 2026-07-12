#!/usr/bin/env bash
# Category: kind
# Delete the Kind cluster used as LocalStack EKS backend.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-testinfra-eks}"
KUBE_DIR="${KIND_KUBE_DIR:-$ROOT/.kube}"

if [[ -x "$ROOT/bin/kind" ]]; then
  export PATH="$ROOT/bin:$PATH"
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "kind not found; nothing to delete."
  exit 0
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> Deleting Kind cluster '$CLUSTER_NAME'..."
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "==> Kind cluster '$CLUSTER_NAME' not found."
fi

rm -f "$KUBE_DIR/kind-config" "$KUBE_DIR/kind-config.localstack" 2>/dev/null || true
echo "Done."
