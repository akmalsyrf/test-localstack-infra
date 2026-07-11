#!/usr/bin/env bash
# Start Kind (EKS backend) then LocalStack, then bridge Docker networks.
#
# Startup order (required for Kind↔LocalStack messaging bridge):
#   1) Kind cluster (creates Docker network `kind`)
#   2) LocalStack container (default compose network)
#   3) docker network connect kind testinfra-localstack  (idempotent)
# Terraform eks apply then discovers LocalStack's IP on `kind` via
# modules/eks/scripts/localstack-network-info.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_KIND="${SKIP_KIND:-0}"
LS_CONTAINER="${LOCALSTACK_CONTAINER:-testinfra-localstack}"
KIND_DOCKER_NETWORK="${KIND_DOCKER_NETWORK:-kind}"

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

    # Bridge LocalStack onto the Kind Docker network so pods can reach :4566.
    if [[ "$SKIP_KIND" != "1" ]] && docker network inspect "$KIND_DOCKER_NETWORK" >/dev/null 2>&1; then
      echo "==> Connecting $LS_CONTAINER to Docker network '$KIND_DOCKER_NETWORK' (idempotent)..."
      docker network connect "$KIND_DOCKER_NETWORK" "$LS_CONTAINER" 2>/dev/null || true
      LS_IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${KIND_DOCKER_NETWORK}\").IPAddress }}" "$LS_CONTAINER" 2>/dev/null || true)"
      if [[ -n "$LS_IP" && "$LS_IP" != "<no value>" ]]; then
        echo "    LocalStack on kind network: $LS_IP"
      else
        echo "WARNING: could not resolve LocalStack IP on '$KIND_DOCKER_NETWORK'" >&2
      fi
    fi
    exit 0
  fi
  sleep 2
done

echo "LocalStack did not become healthy in time." >&2
docker compose logs --tail=80
exit 1
