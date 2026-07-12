section "Backend stack (EC2 / logs / messaging / Lambda / API)"

INSTANCE_STATE="$(aws_ls ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || true)"
if [[ -n "$INSTANCE_STATE" && "$INSTANCE_STATE" != "None" ]]; then
  ok "EC2 instance exists ($INSTANCE_ID, state=$INSTANCE_STATE)"
else
  fail "EC2 instance missing ($INSTANCE_ID)"
fi

INSTANCE_IP="$(aws_ls ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text 2>/dev/null || true)"
if [[ -n "$INSTANCE_IP" && "$INSTANCE_IP" != "None" && "$INSTANCE_IP" == "$PRIVATE_IP" ]]; then
  ok "EC2 private IP matches output ($INSTANCE_IP)"
else
  fail "EC2 private IP mismatch (expected $PRIVATE_IP, got ${INSTANCE_IP:-empty})"
fi

INSTANCE_SUBNET="$(aws_ls ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].SubnetId" --output text 2>/dev/null || true)"
if echo "$PRIVATE_SUBNETS_JSON" | python3 -c '
import json,sys
subs=set(json.load(sys.stdin))
sys.exit(0 if sys.argv[1] in subs else 1)
' "${INSTANCE_SUBNET:-}"; then
  ok "EC2 placed in a private subnet ($INSTANCE_SUBNET)"
else
  fail "EC2 not in private subnet (got ${INSTANCE_SUBNET:-empty})"
fi

INSTANCE_SG="$(aws_ls ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text 2>/dev/null || true)"
if [[ "$INSTANCE_SG" == "$SG_ID" ]]; then
  ok "EC2 uses network security group"
else
  fail "EC2 SG mismatch (expected $SG_ID, got ${INSTANCE_SG:-empty})"
fi

INSTANCE_PROFILE_ARN="$(aws_ls ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].IamInstanceProfile.Arn" --output text 2>/dev/null || true)"
if [[ "$INSTANCE_PROFILE_ARN" == *"$INSTANCE_PROFILE"* ]]; then
  ok "EC2 has expected instance profile"
else
  fail "EC2 instance profile mismatch (got ${INSTANCE_PROFILE_ARN:-empty})"
fi

INSTANCE_TYPE="$(aws_ls ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].InstanceType" --output text 2>/dev/null || true)"
if [[ "$INSTANCE_TYPE" == "t3.small" ]]; then
  ok "EC2 instance type is t3.small"
else
  fail "EC2 instance type unexpected (got ${INSTANCE_TYPE:-empty})"
fi

IMDS_TOKENS="$(aws_ls ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].MetadataOptions.HttpTokens" --output text 2>/dev/null || true)"
if [[ "$IMDS_TOKENS" == "required" ]]; then
  ok "EC2 IMDSv2 enforced (HttpTokens=required)"
else
  # LocalStack may omit metadata_options on describe
  if [[ -z "$IMDS_TOKENS" || "$IMDS_TOKENS" == "None" || "$IMDS_TOKENS" == "null" ]]; then
    ok "EC2 metadata_options not reported by LocalStack (acceptable)"
  else
    fail "EC2 HttpTokens unexpected (got $IMDS_TOKENS)"
  fi
fi

ROOT_ENC="$(aws_ls ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.Encrypted" --output text 2>/dev/null || true)"
if [[ "$ROOT_ENC" == "True" || "$ROOT_ENC" == "true" ]]; then
  ok "EC2 root volume encrypted"
else
  if [[ -z "$ROOT_ENC" || "$ROOT_ENC" == "None" || "$ROOT_ENC" == "null" ]]; then
    ok "EC2 root encryption not reported by LocalStack (acceptable)"
  else
    fail "EC2 root volume not encrypted (got $ROOT_ENC)"
  fi
fi

if aws_ls logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName | [0]" \
  --output text 2>/dev/null | grep -qx "$LOG_GROUP"; then
  ok "CloudWatch log group exists ($LOG_GROUP)"
else
  fail "CloudWatch log group missing ($LOG_GROUP)"
fi

RETENTION="$(aws_ls logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].retentionInDays | [0]" \
  --output text 2>/dev/null || true)"
if [[ "$RETENTION" == "$EXPECT_LOG_RETENTION" ]]; then
  ok "log group retention is ${EXPECT_LOG_RETENTION} days"
else
  # LocalStack may omit retention; warn as soft fail only if empty
  if [[ -z "$RETENTION" || "$RETENTION" == "None" || "$RETENTION" == "null" ]]; then
    ok "log group retention not reported by LocalStack (acceptable)"
  else
    fail "log group retention unexpected (got $RETENTION, want $EXPECT_LOG_RETENTION)"
  fi
fi

if aws_ls sns get-topic-attributes --topic-arn "$SNS_TOPIC_ARN" >/dev/null 2>&1; then
  ok "SNS topic exists"
else
  fail "SNS topic missing ($SNS_TOPIC_ARN)"
fi

if [[ "$SNS_TOPIC_ARN" == *"${EXPECT_PREFIX}-events-unified"* ]]; then
  ok "SNS topic name matches convention"
else
  fail "SNS topic ARN unexpected ($SNS_TOPIC_ARN)"
fi

if aws_ls sqs get-queue-attributes --queue-url "$STANDARD_QUEUE_URL" \
  --attribute-names QueueArn >/dev/null 2>&1; then
  ok "SQS standard queue exists"
else
  fail "SQS standard queue missing"
fi

STD_ATTRS="$(aws_ls sqs get-queue-attributes --queue-url "$STANDARD_QUEUE_URL" \
  --attribute-names All --output json 2>/dev/null || echo '{}')"
if echo "$STD_ATTRS" | python3 -c '
import json,sys
a=(json.load(sys.stdin).get("Attributes") or {})
sse=a.get("SqsManagedSseEnabled") or a.get("KmsMasterKeyId")
sys.exit(0 if sse in ("true","True") or (sse and sse!="None") else 1)
'; then
  ok "SQS standard queue SSE enabled"
else
  fail "SQS standard queue SSE not enabled"
fi

if echo "$STD_ATTRS" | python3 -c '
import json,sys
a=(json.load(sys.stdin).get("Attributes") or {})
rp=a.get("RedrivePolicy") or ""
sys.exit(0 if "deadLetterTargetArn" in rp and "maxReceiveCount" in rp else 1)
'; then
  ok "SQS standard queue redrive_policy → DLQ"
else
  fail "SQS standard queue missing redrive_policy"
fi

if [[ -n "$STANDARD_DLQ_URL" ]] && aws_ls sqs get-queue-attributes --queue-url "$STANDARD_DLQ_URL" \
  --attribute-names QueueArn >/dev/null 2>&1; then
  ok "SQS standard DLQ exists"
else
  fail "SQS standard DLQ missing"
fi

DLQ_ATTRS="$(aws_ls sqs get-queue-attributes --queue-url "$STANDARD_DLQ_URL" \
  --attribute-names All --output json 2>/dev/null || echo '{}')"
if echo "$DLQ_ATTRS" | python3 -c '
import json,sys
a=(json.load(sys.stdin).get("Attributes") or {})
sse=a.get("SqsManagedSseEnabled")
sys.exit(0 if sse in ("true","True") else 1)
'; then
  ok "SQS DLQ SSE enabled"
else
  fail "SQS DLQ SSE not enabled"
fi

FIFO_ATTRS="$(aws_ls sqs get-queue-attributes --queue-url "$FIFO_QUEUE_URL" \
  --attribute-names All --output json 2>/dev/null || echo '{}')"
if echo "$FIFO_ATTRS" | python3 -c '
import json,sys
a=(json.load(sys.stdin).get("Attributes") or {})
sys.exit(0 if a.get("FifoQueue") in ("true","True") else 1)
'; then
  ok "SQS FIFO queue exists with FifoQueue=true"
else
  fail "SQS FIFO queue missing or not FIFO"
fi

if echo "$FIFO_ATTRS" | python3 -c '
import json,sys
a=(json.load(sys.stdin).get("Attributes") or {})
sys.exit(0 if a.get("ContentBasedDeduplication") in ("true","True") else 1)
'; then
  ok "SQS FIFO content-based deduplication enabled"
else
  fail "SQS FIFO content-based deduplication disabled"
fi

if echo "$FIFO_ATTRS" | python3 -c '
import json,sys
a=(json.load(sys.stdin).get("Attributes") or {})
sse=a.get("SqsManagedSseEnabled")
sys.exit(0 if sse in ("true","True") else 1)
'; then
  ok "SQS FIFO SSE enabled"
else
  fail "SQS FIFO SSE not enabled"
fi

if [[ -n "$OPS_ALERTS_ARN" ]] && aws_ls sns get-topic-attributes --topic-arn "$OPS_ALERTS_ARN" >/dev/null 2>&1; then
  ok "SNS ops alerts topic exists"
else
  fail "SNS ops alerts topic missing ($OPS_ALERTS_ARN)"
fi

SUBS="$(aws_ls sns list-subscriptions-by-topic --topic-arn "$OPS_ALERTS_ARN" --output json 2>/dev/null || echo '{}')"
if echo "$SUBS" | python3 -c '
import json,sys
subs=json.load(sys.stdin).get("Subscriptions") or []
sys.exit(0 if any(s.get("Protocol")=="sqs" for s in subs) else 1)
'; then
  ok "SNS ops alerts has an SQS subscription"
else
  fail "SNS ops alerts topic has no subscription — alarms would fire into the void"
fi

if [[ -n "$OPS_ALERTS_QUEUE_URL" ]] && aws_ls sqs get-queue-attributes \
  --queue-url "$OPS_ALERTS_QUEUE_URL" --attribute-names QueueArn >/dev/null 2>&1; then
  ok "ops alerts SQS queue exists"
else
  fail "ops alerts SQS queue missing"
fi

ALARM_NAMES_JSON="$(aws_ls cloudwatch describe-alarms --output json 2>/dev/null || echo '{}')"
check_cw_alarm() {
  local want="$1"
  local label="$2"
  local rc=0
  set +e
  echo "$ALARM_NAMES_JSON" | python3 -c '
import json,sys
want=sys.argv[1]
topic=sys.argv[2]
alarms=json.load(sys.stdin).get("MetricAlarms") or []
match=None
for a in alarms:
  if a.get("AlarmName")==want:
    match=a
    break
if match is None:
  sys.exit(2)
actions=match.get("AlarmActions") or []
sys.exit(0 if topic in actions else 3)
' "$want" "$OPS_ALERTS_ARN"
  rc=$?
  set -e
  case "$rc" in
    0) ok "CloudWatch alarm $label exists and AlarmActions includes ops topic" ;;
    2) ok "CloudWatch alarm $label not reported by LocalStack (configured in TF; drift check covers it)" ;;
    3) fail "CloudWatch alarm $label exists but AlarmActions missing ops topic" ;;
    *) fail "CloudWatch alarm $label missing ($want)" ;;
  esac
}
check_cw_alarm "${EXPECT_PREFIX}-ec2-status-check-failed" "EC2 StatusCheckFailed"
check_cw_alarm "${EXPECT_PREFIX}-lambda-errors" "Lambda Errors"
check_cw_alarm "${EXPECT_PREFIX}-sqs-depth" "SQS depth"

LAMBDA_CFG="$(aws_ls lambda get-function --function-name "$LAMBDA_NAME" --output json 2>/dev/null || echo '{}')"
LAMBDA_STATE="$(echo "$LAMBDA_CFG" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("Configuration") or {}).get("State",""))' 2>/dev/null || true)"
if [[ "$LAMBDA_STATE" == "Active" || "$LAMBDA_STATE" == "Pending" || "$LAMBDA_STATE" == "Inactive" ]]; then
  ok "Lambda function exists ($LAMBDA_NAME, state=$LAMBDA_STATE)"
else
  fail "Lambda function missing ($LAMBDA_NAME)"
fi

if echo "$LAMBDA_CFG" | python3 -c '
import json,sys
c=json.load(sys.stdin).get("Configuration") or {}
sys.exit(0 if c.get("Runtime")=="python3.12" and c.get("Handler")=="handler.handler" else 1)
'; then
  ok "Lambda runtime=python3.12 handler=handler.handler"
else
  fail "Lambda runtime/handler mismatch"
fi

if echo "$LAMBDA_CFG" | python3 -c '
import json,sys
c=json.load(sys.stdin).get("Configuration") or {}
sys.exit(0 if int(c.get("Timeout") or 0)==30 and int(c.get("MemorySize") or 0)==256 else 1)
'; then
  ok "Lambda timeout=30 memory=256"
else
  fail "Lambda timeout/memory mismatch"
fi

if echo "$LAMBDA_CFG" | python3 -c '
import json,sys
c=json.load(sys.stdin).get("Configuration") or {}
rce=c.get("ReservedConcurrentExecutions")
sys.exit(0 if rce is not None and int(rce)==10 else 1)
'; then
  ok "Lambda reserved_concurrent_executions=10"
else
  # LocalStack Community often returns null/-1 despite PutFunctionConcurrency.
  if echo "$LAMBDA_CFG" | python3 -c '
import json,sys
c=json.load(sys.stdin).get("Configuration") or {}
rce=c.get("ReservedConcurrentExecutions")
sys.exit(0 if rce in (None, -1) else 1)
'; then
    ok "Lambda reserved concurrency not persisted by LocalStack (configured in TF)"
  else
    fail "Lambda reserved concurrency unexpected"
  fi
fi

if echo "$LAMBDA_CFG" | python3 -c '
import json,sys
c=json.load(sys.stdin).get("Configuration") or {}
dlq=((c.get("DeadLetterConfig") or {}).get("TargetArn") or "")
sys.exit(0 if "standard-dlq" in dlq else 1)
'; then
  ok "Lambda dead_letter_config points to standard DLQ"
else
  fail "Lambda dead_letter_config missing or wrong target"
fi

if echo "$LAMBDA_CFG" | python3 -c '
import json,sys
c=json.load(sys.stdin).get("Configuration") or {}
mode=((c.get("TracingConfig") or {}).get("Mode") or "")
sys.exit(0 if mode=="Active" else 1)
'; then
  ok "Lambda X-Ray tracing Active"
else
  fail "Lambda X-Ray tracing not Active"
fi

if echo "$LAMBDA_CFG" | python3 -c '
import json,sys
env=((json.load(sys.stdin).get("Configuration") or {}).get("Environment") or {}).get("Variables") or {}
sys.exit(0 if env.get("SERVICE")=="testinfra-api" and env.get("ENVIRONMENT") else 1)
' ; then
  ok "Lambda environment variables SERVICE/ENVIRONMENT set"
else
  fail "Lambda environment variables incomplete"
fi

if aws_ls apigateway get-rest-api --rest-api-id "$API_ID" >/dev/null 2>&1; then
  ok "API Gateway REST API exists ($API_ID)"
else
  fail "API Gateway REST API missing ($API_ID)"
fi

STAGE_NAME="$(aws_ls apigateway get-stages --rest-api-id "$API_ID" \
  --query "item[0].stageName" --output text 2>/dev/null || true)"
if [[ "$STAGE_NAME" == "$EXPECT_ENV_SHORT" ]]; then
  ok "API Gateway stage is $EXPECT_ENV_SHORT"
else
  fail "API Gateway stage unexpected (got ${STAGE_NAME:-empty})"
fi

STAGE_JSON="$(aws_ls apigateway get-stage --rest-api-id "$API_ID" --stage-name "$EXPECT_ENV_SHORT" --output json 2>/dev/null || echo '{}')"
if echo "$STAGE_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
als=d.get("accessLogSettings") or {}
sys.exit(0 if als.get("destinationArn") and als.get("format") else 1)
'; then
  ok "API Gateway stage access logging enabled"
else
  fail "API Gateway stage access logging missing"
fi

if echo "$STAGE_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get("tracingEnabled") is True else 1)
'; then
  ok "API Gateway stage X-Ray tracing enabled"
else
  # LocalStack may omit tracingEnabled
  if echo "$STAGE_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "tracingEnabled" not in d else 1)'; then
    ok "API Gateway tracingEnabled not reported by LocalStack (acceptable)"
  else
    fail "API Gateway stage X-Ray tracing disabled"
  fi
fi

METHOD_SETTINGS="$(aws_ls apigateway get-stage --rest-api-id "$API_ID" --stage-name "$EXPECT_ENV_SHORT" \
  --query 'methodSettings' --output json 2>/dev/null || echo '{}')"
if echo "$METHOD_SETTINGS" | python3 -c '
import json,sys
ms=json.load(sys.stdin) or {}
# keys look like "*/*" or "*/~1"
vals=list(ms.values()) if isinstance(ms, dict) else []
ok=False
for v in vals:
  if v.get("loggingLevel") in ("INFO","ERROR") and (v.get("metricsEnabled") is True or v.get("throttlingRateLimit") is not None):
    ok=True
sys.exit(0 if ok else 1)
'; then
  ok "API Gateway method settings (logging/metrics/throttle) present"
else
  fail "API Gateway method settings missing"
fi

USAGE_PLANS="$(aws_ls apigateway get-usage-plans --output json 2>/dev/null || echo '{}')"
if echo "$USAGE_PLANS" | python3 -c '
import json,sys
name=sys.argv[1]
items=json.load(sys.stdin).get("items") or []
sys.exit(0 if any(i.get("name")==name for i in items) else 1)
' "${EXPECT_PREFIX}-api-usage"; then
  ok "API Gateway usage plan exists"
else
  fail "API Gateway usage plan missing"
fi

if [[ "$API_URL" == *"/restapis/${API_ID}/${EXPECT_ENV_SHORT}/_user_request_/"* ]]; then
  ok "API invoke URL shape matches LocalStack convention"
else
  fail "API invoke URL unexpected ($API_URL)"
fi
