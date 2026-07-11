#!/usr/bin/env bash
# Create Kind cluster that backs LocalStack EKS (EKS_K8S_PROVIDER=local).
# Also writes a LocalStack-friendly kubeconfig (host.docker.internal).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-testinfra-eks}"
KIND_CONFIG="${KIND_CONFIG:-$ROOT/kind/cluster.yaml}"
KUBE_DIR="${KIND_KUBE_DIR:-$ROOT/.kube}"
HOST_KUBECONFIG="${KUBE_DIR}/kind-config"
LS_KUBECONFIG="${KUBE_DIR}/kind-config.localstack"

mkdir -p "$KUBE_DIR"

ensure_kind() {
  if [[ -x "$ROOT/bin/kind" ]]; then
    export PATH="$ROOT/bin:$PATH"
    return 0
  fi
  if command -v kind >/dev/null 2>&1; then
    return 0
  fi
  echo "==> kind not found; installing to ./bin/kind ..."
  local os arch version url
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "Unsupported arch: $arch" >&2; exit 1 ;;
  esac
  version="${KIND_VERSION:-v0.27.0}"
  url="https://kind.sigs.k8s.io/dl/${version}/kind-${os}-${arch}"
  mkdir -p "$ROOT/bin"
  curl -fsSL -o "$ROOT/bin/kind" "$url"
  chmod +x "$ROOT/bin/kind"
  export PATH="$ROOT/bin:$PATH"
}

ensure_kind

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required (install Kubernetes CLI)." >&2
  exit 1
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "==> Kind cluster '$CLUSTER_NAME' already exists."
else
  echo "==> Creating Kind cluster '$CLUSTER_NAME'..."
  kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG" --wait 120s
fi

kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$HOST_KUBECONFIG"
chmod 600 "$HOST_KUBECONFIG" 2>/dev/null || true

# LocalStack runs in Docker and cannot reach 127.0.0.1 on the host.
# Rewrite API server to host.docker.internal (Docker Desktop / Compose extra_hosts).
python3 - "$HOST_KUBECONFIG" "$LS_KUBECONFIG" <<'PY'
import sys
from pathlib import Path

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
text = src.read_text()
# kind exports https://127.0.0.1:<port> or https://localhost:<port>
for host in ("127.0.0.1", "localhost"):
    text = text.replace(f"https://{host}:", "https://host.docker.internal:")
dst.write_text(text)
print(f"wrote {dst}")
PY
chmod 600 "$LS_KUBECONFIG" 2>/dev/null || true

export KUBECONFIG="$HOST_KUBECONFIG"
echo "==> Waiting for Kind nodes Ready..."
kubectl --kubeconfig "$HOST_KUBECONFIG" wait --for=condition=Ready nodes --all --timeout=180s

echo "==> Kind ready."
echo "    Host kubeconfig:       $HOST_KUBECONFIG"
echo "    LocalStack kubeconfig: $LS_KUBECONFIG"
echo "    Context:               kind-${CLUSTER_NAME}"
kubectl --kubeconfig "$HOST_KUBECONFIG" get nodes -o wide
