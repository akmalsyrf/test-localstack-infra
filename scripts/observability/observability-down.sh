#!/usr/bin/env bash
# Category: observability
# Tear down optional Grafana + Loki + Alloy (removes volumes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "==> Stopping observability stack (and removing volumes)..."
docker compose -p testinfra-obs -f docker-compose.observability.yml down -v
echo "Observability stack stopped."
