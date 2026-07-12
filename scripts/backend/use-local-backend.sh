#!/usr/bin/env bash
# Category: backend
# Force local backend (no Terraform Cloud). Recommended for LocalStack.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BACKEND=local "$ROOT/scripts/lifecycle/sync-live.sh"
echo "Live stacks now use backend \"local\"."
echo "Run: ./scripts/lifecycle/env.sh staging apply"
