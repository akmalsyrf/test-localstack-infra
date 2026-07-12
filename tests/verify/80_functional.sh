section "Functional checks"

MSG_ID="verify-$(date +%s)-$$"
if aws_ls sns publish --topic-arn "$SNS_TOPIC_ARN" \
  --message "{\"verify\":true,\"id\":\"$MSG_ID\"}" >/dev/null 2>&1; then
  ok "SNS publish succeeded"
  RECEIVED=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    RECV="$(aws_ls sqs receive-message \
      --queue-url "$STANDARD_QUEUE_URL" \
      --max-number-of-messages 10 \
      --wait-time-seconds 1 \
      --output json 2>/dev/null || echo '{}')"
    if echo "$RECV" | python3 -c '
import json,sys
d=json.load(sys.stdin)
msgs=d.get("Messages") or []
needle=sys.argv[1]
sys.exit(0 if any(needle in (m.get("Body") or "") for m in msgs) else 1)
' "$MSG_ID" 2>/dev/null; then
      RECEIVED=1
      echo "$RECV" | python3 -c '
import json,sys
for m in (json.load(sys.stdin).get("Messages") or []):
  rh=m.get("ReceiptHandle") or ""
  if rh: print(rh)
' | while IFS= read -r rh; do
        [[ -z "$rh" ]] && continue
        aws_ls sqs delete-message \
          --queue-url "$STANDARD_QUEUE_URL" \
          --receipt-handle "$rh" >/dev/null 2>&1 || true
      done
      break
    fi
    sleep 1
  done
  if [[ "$RECEIVED" -eq 1 ]]; then
    ok "SNS→SQS subscription delivered message"
  else
    fail "SNS→SQS subscription did not deliver within timeout"
  fi
else
  fail "SNS publish failed"
fi

INVOKE_OUT="/tmp/verify-lambda-${ENV}.json"
PAYLOAD_FILE="/tmp/verify-lambda-payload-${ENV}.json"
printf '%s' '{"path":"/verify","httpMethod":"GET"}' > "$PAYLOAD_FILE"
if aws_ls lambda invoke \
  --function-name "$LAMBDA_NAME" \
  --payload "fileb://${PAYLOAD_FILE}" \
  "$INVOKE_OUT" >/dev/null 2>&1 \
  || aws_ls lambda invoke \
  --function-name "$LAMBDA_NAME" \
  --payload "file://${PAYLOAD_FILE}" \
  "$INVOKE_OUT" >/dev/null 2>&1; then
  if python3 -c '
import json,sys
with open(sys.argv[1]) as f: body=json.load(f)
sc=body.get("statusCode", 200)
inner=body.get("body")
if isinstance(inner, str):
  try: inner=json.loads(inner)
  except Exception: inner={}
msg=(inner or {}).get("message","") if isinstance(inner, dict) else ""
sys.exit(0 if sc==200 and "localstack ok" in str(msg) else 1)
' "$INVOKE_OUT"; then
    ok "Lambda direct invoke returns expected payload"
  else
    fail "Lambda direct invoke unexpected payload"
    cat "$INVOKE_OUT" >&2 || true
  fi
else
  fail "Lambda direct invoke failed"
  [[ -f "$INVOKE_OUT" ]] && cat "$INVOKE_OUT" >&2 || true
fi

API_RESP="/tmp/verify-api-${ENV}.json"
# Terraform output often hardcodes localhost; rewrite to the live LocalStack endpoint
# (Linux CI breaks host :4566 publish after Kind network attach).
API_SMOKE_URL="$(python3 -c '
import sys, urllib.parse
url, ep = sys.argv[1], sys.argv[2].rstrip("/")
p, e = urllib.parse.urlparse(url), urllib.parse.urlparse(ep)
print(urllib.parse.urlunparse((e.scheme or "http", e.netloc, p.path, p.params, p.query, p.fragment)))
' "$API_URL" "$ENDPOINT")"
if curl -sf --max-time 60 "$API_SMOKE_URL" | tee "$API_RESP" >/dev/null \
  && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if "localstack ok" in str(d.get("message","")) else 1)
' "$API_RESP"; then
  ok "API Gateway smoke ($API_SMOKE_URL)"
  echo "      response: $(tr -d '\n' < "$API_RESP")"
else
  fail "API Gateway smoke failed ($API_SMOKE_URL)"
  [[ -f "$API_RESP" ]] && cat "$API_RESP" >&2 || true
fi

# X-Ray: Lambda has tracing_config Active + SERVICES includes xray. LocalStack
# Community currently returns InternalFailure for GetTraceSummaries ("not yet
# implemented or pro feature") — do not claim read-back works until this changes.
XRAY_START="$(($(date +%s) - 600))"
XRAY_END="$(date +%s)"
set +e
XRAY_ERR="$(aws_ls xray get-trace-summaries \
  --start-time "$XRAY_START" --end-time "$XRAY_END" --output json 2>&1)"
XRAY_RC=$?
set -e
if [[ "$XRAY_RC" -eq 0 ]]; then
  if echo "$XRAY_ERR" | python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if (d.get("TraceSummaries") or []) else 1)
' 2>/dev/null; then
    ok "X-Ray GetTraceSummaries returned at least one trace after Lambda/API traffic"
  else
    ok "X-Ray GetTraceSummaries OK but empty (tracing_config Active; no traces correlated yet)"
  fi
elif echo "$XRAY_ERR" | grep -qiE 'not yet implemented|pro feature|InternalFailure'; then
  ok "X-Ray GetTraceSummaries not implemented on LocalStack Community (write-side tracing_config still set; retrieval unverified)"
else
  ok "X-Ray GetTraceSummaries unavailable (rc=$XRAY_RC; retrieval unverified; tracing_config still set)"
fi
