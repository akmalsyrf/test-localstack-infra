#!/usr/bin/env bash
# Category: debug
# Stop Portainer without deleting its data volume (keeps admin user).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "==> Stopping Portainer (preserving portainer-data volume)..."
docker compose --profile debug stop portainer
echo "Portainer stopped. Re-start with ./scripts/debug/portainer-up.sh"
