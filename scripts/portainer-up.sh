#!/usr/bin/env bash
# Start Portainer CE (local-dev debug UI). Opt-in via Compose profile "debug".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Starting Portainer CE (--profile debug)..."
docker compose --profile debug up -d portainer

echo "==> Waiting for Portainer..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:9000 >/dev/null 2>&1 \
    || curl -sf -o /dev/null -w "%{http_code}" http://localhost:9000 2>/dev/null | grep -qE '^[23]'; then
    echo ""
    echo "Portainer is up: http://localhost:9000"
    echo "  First visit: create the local admin user."
    echo ""
    echo "Import Kind (one-time, manual UI):"
    echo "  Environments → Add environment → Kubernetes → Import kubeconfig"
    echo "  File: $ROOT/.kube/kind-config  (created by ./scripts/kind-up.sh)"
    echo ""
    echo "NOTE: Portainer mounts the host docker.sock, so it lists ALL containers"
    echo "(LocalStack = testinfra-localstack, Kind node containers, etc.). That is"
    echo "intentional for unified Docker + K8s visibility."
    echo "Stop with ./scripts/portainer-down.sh (keeps Portainer data / admin user)."
    exit 0
  fi
  sleep 2
done

echo "Portainer did not become ready in time." >&2
docker compose --profile debug logs portainer --tail=80
exit 1
