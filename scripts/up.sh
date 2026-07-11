#!/usr/bin/env bash
# Start Kind (EKS backend) then LocalStack.
#
# Kind pods reach LocalStack via host.docker.internal → host :4566 (see
# modules/eks/scripts/localstack-network-info.sh). We intentionally do NOT
# `docker network connect` LocalStack onto `kind` by default — on Linux CI that
# often breaks published :4566.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_KIND="${SKIP_KIND:-0}"
LS_CONTAINER="${LOCALSTACK_CONTAINER:-testinfra-localstack}"
KIND_DOCKER_NETWORK="${KIND_DOCKER_NETWORK:-kind}"
# Opt-in legacy bridge (usually unnecessary).
CONNECT_LS_TO_KIND="${CONNECT_LS_TO_KIND:-0}"

if [[ "$SKIP_KIND" != "1" ]]; then
  echo "==> Ensuring Kind cluster (LocalStack EKS backend)..."
  "$ROOT/scripts/kind-up.sh"
else
  # CI: start LocalStack alone so shared/network/backend apply without Kind
  # contending for Docker/CPU. Call kind-up.sh later, before the eks stack.
  echo "==> SKIP_KIND=1 — LocalStack only (Kind deferred)"
  if [[ ! -f "$ROOT/.kube/kind-config.localstack" ]]; then
    mkdir -p "$ROOT/.kube"
    # Placeholder so compose volume mount succeeds; replace when kind-up.sh runs.
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

    if [[ "$CONNECT_LS_TO_KIND" == "1" && "$SKIP_KIND" != "1" ]] \
      && docker network inspect "$KIND_DOCKER_NETWORK" >/dev/null 2>&1; then
      echo "==> CONNECT_LS_TO_KIND=1 — attaching $LS_CONTAINER to '$KIND_DOCKER_NETWORK'..."
      docker network connect "$KIND_DOCKER_NETWORK" "$LS_CONTAINER" 2>/dev/null || true
    fi
    exit 0
  fi
  sleep 2
done

echo "LocalStack did not become healthy in time." >&2
docker compose logs --tail=80
exit 1
