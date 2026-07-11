#!/usr/bin/env bash
# Apply all environments (local backend → LocalStack)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for env in staging dev; do
  "$ROOT/scripts/env.sh" "$env" apply
done
