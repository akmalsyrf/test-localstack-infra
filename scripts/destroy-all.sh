#!/usr/bin/env bash
# Destroy all environments (reverse order per env)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for env in staging dev; do
  "$ROOT/scripts/env.sh" "$env" destroy || true
done
