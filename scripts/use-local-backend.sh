#!/usr/bin/env bash
# Force local backend (no Terraform Cloud). Recommended for LocalStack.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND=local "$ROOT/scripts/sync-live.sh"
echo "Live stacks now use backend \"local\"."
echo "Run: ./scripts/env.sh staging apply"
