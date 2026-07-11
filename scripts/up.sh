#!/usr/bin/env bash
# Start Kind (EKS backend) then LocalStack.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_KIND="${SKIP_KIND:-0}"

if [[ "$SKIP_KIND" != "1" ]]; then
  echo "==> Ensuring Kind cluster (LocalStack EKS backend)..."
  "$ROOT/scripts/kind-up.sh"
else
  echo "==> SKIP_KIND=1 — expecting an existing kubeconfig at .kube/kind-config.localstack"
  if [[ ! -f "$ROOT/.kube/kind-config.localstack" ]]; then
    mkdir -p "$ROOT/.kube"
    # Placeholder so compose volume mount succeeds; EKS calls will fail until Kind is up.
    printf '%s\n' "apiVersion: v1" "kind: Config" "clusters: []" "contexts: []" "users: []" \
      > "$ROOT/.kube/kind-config.localstack"
  fi
fi

echo "==> Starting LocalStack (free)..."
docker compose up -d

echo "==> Waiting for LocalStack health..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:4566/_localstack/health >/dev/null 2>&1; then
    echo "LocalStack is healthy."
    exit 0
  fi
  sleep 2
done

echo "LocalStack did not become healthy in time." >&2
docker compose logs --tail=80
exit 1
