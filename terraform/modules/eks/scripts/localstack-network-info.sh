#!/usr/bin/env bash
# Terraform external data source: IP Kind pods should use to reach LocalStack :4566.
#
# Prefer host.docker.internal (Kind node → host port publish). That avoids
# `docker network connect` attaching LocalStack to the `kind` network, which on
# Linux CI often breaks host :4566 and tempts a restart that wipes PERSISTENCE=0 state.
#
# Fallback: connect container to `kind` and use its IP (local Docker Desktop / older flows).
#
# stdin: JSON {container_name?, cluster_name?}
set -euo pipefail

QUERY="$(cat)"
eval "$(python3 -c '
import json,sys,shlex
q=json.load(sys.stdin)
print("CONTAINER="+shlex.quote(q.get("container_name") or "testinfra-localstack"))
print("CLUSTER="+shlex.quote(q.get("cluster_name") or "testinfra-eks"))
' <<<"$QUERY")"
NETWORK="${KIND_DOCKER_NETWORK:-kind}"

if ! command -v docker >/dev/null 2>&1; then
  echo 'docker not found' >&2
  exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "container '$CONTAINER' not found — run scripts/up.sh first" >&2
  exit 1
fi

CP="$(docker ps -q -f "name=${CLUSTER}-control-plane" | head -1 || true)"
IP=""
MODE=""

if [[ -n "$CP" ]]; then
  # IPv4 for host.docker.internal as seen from the Kind control-plane node.
  IP="$(docker exec "$CP" getent ahostsv4 host.docker.internal 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ -n "$IP" ]]; then
    if docker exec "$CP" curl -sf --max-time 5 "http://${IP}:4566/_localstack/health" >/dev/null 2>&1; then
      MODE="host-gateway"
    else
      IP=""
    fi
  fi
fi

if [[ -z "$IP" ]]; then
  docker network connect "$NETWORK" "$CONTAINER" >/dev/null 2>&1 || true
  IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${NETWORK}\").IPAddress }}" "$CONTAINER" 2>/dev/null || true)"
  MODE="kind-network"
fi

if [[ -z "$IP" || "$IP" == "<no value>" ]]; then
  echo "could not resolve LocalStack reachability from Kind (host.docker.internal or network '$NETWORK')" >&2
  exit 1
fi

python3 -c 'import json,sys; print(json.dumps({"ip": sys.argv[1], "network": sys.argv[2], "container": sys.argv[3], "mode": sys.argv[4]}))' \
  "$IP" "$NETWORK" "$CONTAINER" "$MODE"
