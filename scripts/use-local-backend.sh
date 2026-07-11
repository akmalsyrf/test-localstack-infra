#!/usr/bin/env bash
# Force local backend (no Terraform Cloud).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND=local "$ROOT/scripts/sync-live.sh"
echo "Live stacks now use backend \"local\". Run: terraform -chdir=<stack> init -reconfigure"
