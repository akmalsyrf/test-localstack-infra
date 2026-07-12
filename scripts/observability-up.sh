#!/usr/bin/env bash
# Start optional Grafana + Loki + Promtail (local-dev only; never used by CI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Starting observability stack (Grafana OSS / Loki / Promtail)..."
# Separate Compose project so down -v does not touch LocalStack's network/volumes.
docker compose -p testinfra-obs -f docker-compose.observability.yml up -d

echo "==> Waiting for Grafana health..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:3000/api/health >/dev/null 2>&1; then
    echo ""
    echo "Observability stack is up."
    echo "  Grafana:  http://localhost:3000  (admin / admin — change on first login)"
    echo "  Loki:     http://localhost:3100"
    echo "  Datasource Loki is provisioned as default; open Explore or the"
    echo "  'Kind / Docker logs (local-dev)' dashboard."
    echo ""
    echo "NOTE: This stack uses meaningful CPU/RAM. Stop with ./scripts/observability-down.sh"
    echo "when finished. Not started by ./scripts/up.sh or any CI workflow."
    exit 0
  fi
  sleep 2
done

echo "Grafana did not become healthy in time." >&2
docker compose -p testinfra-obs -f docker-compose.observability.yml logs --tail=80
exit 1
