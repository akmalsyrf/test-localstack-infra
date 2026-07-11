#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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
