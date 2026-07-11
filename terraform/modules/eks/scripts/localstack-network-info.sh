#!/usr/bin/env bash
# Terraform external data source: LocalStack IP on the Kind Docker network.
# stdin: JSON query {container_name} (optional, default testinfra-localstack)
# Requires: scripts/up.sh connected the container to the `kind` network first.
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

# Idempotent: ensure LocalStack is on the Kind network (up.sh also does this).
docker network connect "$NETWORK" "$CONTAINER" >/dev/null 2>&1 || true

IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${NETWORK}\").IPAddress }}" "$CONTAINER" 2>/dev/null || true)"
if [[ -z "$IP" || "$IP" == "<no value>" ]]; then
  echo "container '$CONTAINER' has no IP on Docker network '$NETWORK' — run scripts/up.sh" >&2
  exit 1
fi

python3 -c 'import json,sys; print(json.dumps({"ip": sys.argv[1], "network": sys.argv[2], "container": sys.argv[3]}))' \
  "$IP" "$NETWORK" "$CONTAINER"
