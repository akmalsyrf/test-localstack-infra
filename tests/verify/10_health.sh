section "LocalStack health"
ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
if ! HEALTH="$(curl -sf --max-time 5 "$ENDPOINT/_localstack/health")"; then
  # Linux CI: kind-network attach can break localhost publish; try container IP.
  LS_IP="$(docker inspect -f '{{range $n,$c := .NetworkSettings.Networks}}{{if ne $n "kind"}}{{println $c.IPAddress}}{{end}}{{end}}' "$LS_CONTAINER" 2>/dev/null | awk 'NF{print; exit}' || true)"
  if [[ -z "$LS_IP" ]]; then
    LS_IP="$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${KIND_DOCKER_NETWORK}\").IPAddress }}" "$LS_CONTAINER" 2>/dev/null || true)"
  fi
  if [[ -n "$LS_IP" && "$LS_IP" != "<no value>" ]] && HEALTH="$(curl -sf --max-time 5 "http://${LS_IP}:4566/_localstack/health")"; then
    ENDPOINT="http://${LS_IP}:4566"
    export LOCALSTACK_ENDPOINT="$ENDPOINT"
    echo "Using LocalStack container IP endpoint: $ENDPOINT"
  else
    fail "LocalStack health endpoint unreachable"
    echo "Cannot continue without LocalStack." >&2
    exit 1
  fi
fi
export LOCALSTACK_ENDPOINT="$ENDPOINT"
echo "Resolved LocalStack endpoint: $ENDPOINT"
if echo "$HEALTH" | python3 -c '
import json,sys
h=json.load(sys.stdin)
services=h.get("services") or {}
needed=["s3","iam","ec2","lambda","apigateway","sqs","sns","logs","secretsmanager","dynamodb","cloudwatch"]
bad=[s for s in needed if services.get(s) not in ("available","running")]
if bad:
  print("unhealthy:", ",".join(bad)); sys.exit(1)
print("services ok:", ",".join(needed))
'; then
  ok "LocalStack health (required services available)"
else
  fail "LocalStack health JSON missing required services"
  exit 1
fi

section "LocalStack responsiveness"
LATENCY_MAX="${LOCALSTACK_LATENCY_MAX_SECONDS:-5}"
START_LS="$(date +%s)"
set +e
timeout 10 aws --endpoint-url="$ENDPOINT" --region "$REGION" s3 ls >/dev/null 2>&1
LS_RC=$?
set -e
LS_ELAPSED=$(( $(date +%s) - START_LS ))
echo "LocalStack s3 ls took ${LS_ELAPSED}s (budget ${LATENCY_MAX}s)"
if [[ "$LS_RC" -ne 0 ]]; then
  fail "LocalStack s3 ls failed (exit $LS_RC) after ${LS_ELAPSED}s — Docker/LocalStack may be wedged"
elif [[ "$LS_ELAPSED" -gt "$LATENCY_MAX" ]]; then
  fail "LocalStack responded slowly (${LS_ELAPSED}s > ${LATENCY_MAX}s) — likely CPU/Docker contention"
else
  ok "LocalStack s3 ls within ${LATENCY_MAX}s (${LS_ELAPSED}s)"
fi
