#!/usr/bin/env bash
# Terraform external data source: IP Kind pods use for LocalStack :4566.
#
# Always use LocalStack's address on the Docker `kind` network (idempotent connect).
# Host Terraform must NOT rely on localhost after that attach on Linux CI — scripts/env.sh
# switches TF_VAR_localstack_endpoint to the container's compose-network IP when needed.
#
# stdin: JSON {container_name?}
set -euo pipefail

QUERY="$(cat)"
CONTAINER="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("container_name") or "testinfra-localstack")' <<<"$QUERY")"
NETWORK="${KIND_DOCKER_NETWORK:-kind}"

if ! command -v docker >/dev/null 2>&1; then
  echo 'docker not found' >&2
  exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "container '$CONTAINER' not found — run scripts/up.sh first" >&2
  exit 1
fi

docker network connect "$NETWORK" "$CONTAINER" >/dev/null 2>&1 || true

IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${NETWORK}\").IPAddress }}" "$CONTAINER" 2>/dev/null || true)"
if [[ -z "$IP" || "$IP" == "<no value>" ]]; then
  echo "container '$CONTAINER' has no IP on Docker network '$NETWORK'" >&2
  exit 1
fi

python3 -c 'import json,sys; print(json.dumps({"ip": sys.argv[1], "network": sys.argv[2], "container": sys.argv[3], "mode": "kind-network"}))' \
  "$IP" "$NETWORK" "$CONTAINER"
