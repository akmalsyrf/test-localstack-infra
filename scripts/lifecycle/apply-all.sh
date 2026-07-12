#!/usr/bin/env bash
# Category: lifecycle
# Apply all environments (local backend → LocalStack)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for env in staging production dev; do
  "$ROOT/scripts/lifecycle/env.sh" "$env" apply
done
