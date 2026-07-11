#!/usr/bin/env bash
# Comprehensive post-apply verification against LocalStack.
# Usage: verify-apply.sh <dev|staging>
# Compatible with Bash 3.2+ (macOS /bin/bash) and Bash 4+/5 (CI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:-}"
ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"

PASS=0
FAIL=0

if [[ -z "$ENV" || ! -d "$ROOT/terraform/live/$ENV" ]]; then
  echo "Usage: $0 <dev|staging>" >&2
  exit 1
fi

LIVE="$ROOT/terraform/live/$ENV"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_EC2_METADATA_DISABLED=true

aws_ls() {
  aws --endpoint-url="$ENDPOINT" --region "$REGION" "$@"
}

ok() {
  PASS=$((PASS + 1))
  echo "  PASS  $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL  $1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

tf_out() {
  local stack="$1"
  local name="$2"
  terraform -chdir="$LIVE/$stack" output -raw "$name" 2>/dev/null
}

tf_out_json() {
  local stack="$1"
  local name="$2"
  terraform -chdir="$LIVE/$stack" output -json "$name" 2>/dev/null
}

require_out() {
  # require_out <var_name> <stack> <output_name>
  local var_name="$1"
  local stack="$2"
  local name="$3"
  local val
  if val="$(tf_out "$stack" "$name")" && [[ -n "$val" ]]; then
    printf -v "$var_name" '%s' "$val"
    ok "output ${stack}.${name}"
  else
    printf -v "$var_name" '%s' ""
    fail "output ${stack}.${name} missing"
  fi
}

section() {
  echo ""
  echo "==> $1"
}

json_list_len() {
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
}

json_list_lines() {
  python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))'
}

# --- prerequisites -----------------------------------------------------------

require_cmd aws
require_cmd terraform
require_cmd curl
require_cmd python3

echo "======== VERIFY APPLY: $ENV ========"
echo "LocalStack endpoint: $ENDPOINT"
echo "Region:              $REGION"

section "LocalStack health"
if HEALTH="$(curl -sf "$ENDPOINT/_localstack/health")"; then
  echo "$HEALTH" | python3 -c '
import json,sys
h=json.load(sys.stdin)
services=h.get("services") or {}
needed=["s3","iam","ec2","lambda","apigateway","sqs","sns","logs","secretsmanager"]
bad=[s for s in needed if services.get(s) not in ("available","running")]
if bad:
  print("unhealthy:", ",".join(bad)); sys.exit(1)
print("services ok:", ",".join(needed))
'
  ok "LocalStack health (required services available)"
else
  fail "LocalStack health endpoint unreachable"
  echo "Cannot continue without LocalStack." >&2
  exit 1
fi

# --- collect terraform outputs -----------------------------------------------

section "Terraform outputs"

require_out APP_DATA_BUCKET shared app_data_bucket_id
require_out EC2_BACKEND_BUCKET shared ec2_backend_bucket_id
require_out SECRET_ARN shared secret_arn
require_out SECRET_NAME shared secret_name
require_out INSTANCE_PROFILE shared instance_profile_name
require_out ROLE_NAME shared role_name
require_out POLICY_ARN shared policy_arn

require_out VPC_ID network vpc_id
require_out VPC_CIDR network vpc_cidr_block
require_out SG_ID network security_group_id

PUBLIC_SUBNETS_JSON="$(tf_out_json network public_subnet_ids || true)"
PRIVATE_SUBNETS_JSON="$(tf_out_json network private_subnet_ids || true)"
if [[ -n "$PUBLIC_SUBNETS_JSON" && "$PUBLIC_SUBNETS_JSON" != "null" ]]; then
  ok "output network.public_subnet_ids"
else
  PUBLIC_SUBNETS_JSON="[]"
  fail "output network.public_subnet_ids missing"
fi
if [[ -n "$PRIVATE_SUBNETS_JSON" && "$PRIVATE_SUBNETS_JSON" != "null" ]]; then
  ok "output network.private_subnet_ids"
else
  PRIVATE_SUBNETS_JSON="[]"
  fail "output network.private_subnet_ids missing"
fi

require_out INSTANCE_ID backend instance_id
require_out PRIVATE_IP backend private_ip
require_out LOG_GROUP backend log_group_name
require_out SNS_TOPIC_ARN backend sns_topic_arn
require_out STANDARD_QUEUE_URL backend standard_queue_url
require_out FIFO_QUEUE_URL backend fifo_queue_url
require_out LAMBDA_NAME backend lambda_function_name
require_out API_ID backend api_id
require_out API_URL backend api_invoke_url

if [[ "$FAIL" -gt 0 ]]; then
  echo "Aborting resource checks: terraform outputs incomplete." >&2
  echo "Summary: $PASS passed, $FAIL failed"
  exit 1
fi

# --- shared stack ------------------------------------------------------------

section "Shared stack (S3 / Secrets / IAM)"

if aws_ls s3api head-bucket --bucket "$APP_DATA_BUCKET" >/dev/null 2>&1; then
  ok "S3 app-data bucket exists ($APP_DATA_BUCKET)"
else
  fail "S3 app-data bucket missing ($APP_DATA_BUCKET)"
fi

if aws_ls s3api head-bucket --bucket "$EC2_BACKEND_BUCKET" >/dev/null 2>&1; then
  ok "S3 ec2-backend bucket exists ($EC2_BACKEND_BUCKET)"
else
  fail "S3 ec2-backend bucket missing ($EC2_BACKEND_BUCKET)"
fi

VERIFY_KEY="verify-apply/$(date +%s).txt"
if echo "verify-ok" | aws_ls s3 cp - "s3://${APP_DATA_BUCKET}/$VERIFY_KEY" >/dev/null 2>&1 \
  && GOT="$(aws_ls s3 cp "s3://${APP_DATA_BUCKET}/$VERIFY_KEY" - 2>/dev/null)" \
  && [[ "$GOT" == "verify-ok" ]]; then
  ok "S3 app-data put/get round-trip"
  aws_ls s3 rm "s3://${APP_DATA_BUCKET}/$VERIFY_KEY" >/dev/null 2>&1 || true
else
  fail "S3 app-data put/get round-trip"
fi

if aws_ls secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  ok "Secrets Manager secret exists ($SECRET_NAME)"
else
  fail "Secrets Manager secret missing ($SECRET_NAME)"
fi

if SECRET_VAL="$(aws_ls secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text 2>/dev/null)" \
  && [[ -n "$SECRET_VAL" && "$SECRET_VAL" != "None" ]]; then
  ok "Secrets Manager GetSecretValue returns payload"
else
  fail "Secrets Manager GetSecretValue failed"
fi

if aws_ls iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  ok "IAM role exists ($ROLE_NAME)"
else
  fail "IAM role missing ($ROLE_NAME)"
fi

if aws_ls iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
  ok "IAM instance profile exists ($INSTANCE_PROFILE)"
else
  fail "IAM instance profile missing ($INSTANCE_PROFILE)"
fi

if aws_ls iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  ok "IAM policy exists ($POLICY_ARN)"
else
  fail "IAM policy missing ($POLICY_ARN)"
fi

# --- network stack -----------------------------------------------------------

section "Network stack (VPC / subnets / SG)"

if aws_ls ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query "Vpcs[0].VpcId" --output text 2>/dev/null | grep -qx "$VPC_ID"; then
  ok "VPC exists ($VPC_ID)"
else
  fail "VPC missing ($VPC_ID)"
fi

CIDR_ACTUAL="$(aws_ls ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query "Vpcs[0].CidrBlock" --output text 2>/dev/null || true)"
if [[ "$CIDR_ACTUAL" == "$VPC_CIDR" ]]; then
  ok "VPC CIDR matches output ($CIDR_ACTUAL)"
else
  fail "VPC CIDR mismatch (expected $VPC_CIDR, got ${CIDR_ACTUAL:-empty})"
fi

PUBLIC_COUNT="$(echo "$PUBLIC_SUBNETS_JSON" | json_list_len)"
PRIVATE_COUNT="$(echo "$PRIVATE_SUBNETS_JSON" | json_list_len)"

if [[ "$PUBLIC_COUNT" -ge 1 ]]; then
  # shellcheck disable=SC2046
  if aws_ls ec2 describe-subnets --subnet-ids $(echo "$PUBLIC_SUBNETS_JSON" | json_list_lines | tr '\n' ' ') \
    --query "length(Subnets)" --output text 2>/dev/null | grep -qx "$PUBLIC_COUNT"; then
    ok "public subnets exist ($PUBLIC_COUNT)"
  else
    fail "public subnets missing or incomplete"
  fi
else
  fail "public_subnet_ids empty"
fi

if [[ "$PRIVATE_COUNT" -ge 1 ]]; then
  # shellcheck disable=SC2046
  if aws_ls ec2 describe-subnets --subnet-ids $(echo "$PRIVATE_SUBNETS_JSON" | json_list_lines | tr '\n' ' ') \
    --query "length(Subnets)" --output text 2>/dev/null | grep -qx "$PRIVATE_COUNT"; then
    ok "private subnets exist ($PRIVATE_COUNT)"
  else
    fail "private subnets missing or incomplete"
  fi
else
  fail "private_subnet_ids empty"
fi

if aws_ls ec2 describe-security-groups --group-ids "$SG_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -qx "$SG_ID"; then
  ok "security group exists ($SG_ID)"
else
  fail "security group missing ($SG_ID)"
fi

# --- backend stack -----------------------------------------------------------

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

if aws_ls logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName | [0]" \
  --output text 2>/dev/null | grep -qx "$LOG_GROUP"; then
  ok "CloudWatch log group exists ($LOG_GROUP)"
else
  fail "CloudWatch log group missing ($LOG_GROUP)"
fi

if aws_ls sns get-topic-attributes --topic-arn "$SNS_TOPIC_ARN" >/dev/null 2>&1; then
  ok "SNS topic exists"
else
  fail "SNS topic missing ($SNS_TOPIC_ARN)"
fi

if aws_ls sqs get-queue-attributes --queue-url "$STANDARD_QUEUE_URL" \
  --attribute-names QueueArn >/dev/null 2>&1; then
  ok "SQS standard queue exists"
else
  fail "SQS standard queue missing"
fi

if aws_ls sqs get-queue-attributes --queue-url "$FIFO_QUEUE_URL" \
  --attribute-names FifoQueue >/dev/null 2>&1; then
  ok "SQS FIFO queue exists"
else
  fail "SQS FIFO queue missing"
fi

LAMBDA_STATE="$(aws_ls lambda get-function --function-name "$LAMBDA_NAME" \
  --query "Configuration.State" --output text 2>/dev/null || true)"
if [[ "$LAMBDA_STATE" == "Active" || "$LAMBDA_STATE" == "Pending" || "$LAMBDA_STATE" == "Inactive" ]]; then
  ok "Lambda function exists ($LAMBDA_NAME, state=$LAMBDA_STATE)"
else
  fail "Lambda function missing ($LAMBDA_NAME)"
fi

if aws_ls apigateway get-rest-api --rest-api-id "$API_ID" >/dev/null 2>&1; then
  ok "API Gateway REST API exists ($API_ID)"
else
  fail "API Gateway REST API missing ($API_ID)"
fi

# --- functional checks -------------------------------------------------------

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
if curl -sf --max-time 60 "$API_URL" | tee "$API_RESP" >/dev/null \
  && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if "localstack ok" in str(d.get("message","")) else 1)
' "$API_RESP"; then
  ok "API Gateway smoke ($API_URL)"
  echo "      response: $(tr -d '\n' < "$API_RESP")"
else
  fail "API Gateway smoke failed ($API_URL)"
  [[ -f "$API_RESP" ]] && cat "$API_RESP" >&2 || true
fi

# --- terraform drift (no pending changes) ------------------------------------

section "Terraform drift (plan -detailed-exitcode)"

check_drift() {
  local stack="$1"
  local dir="$LIVE/$stack"
  local plan_file="/tmp/verify-plan-${ENV}-${stack}.txt"
  local attempt rc=1
  # LocalStack can briefly reorder SG/subnet attributes right after apply.
  for attempt in 1 2 3; do
    set +e
    terraform -chdir="$dir" plan -input=false -no-color -detailed-exitcode -lock=false >"$plan_file" 2>&1
    rc=$?
    set -e
    case "$rc" in
      0)
        ok "no drift in $stack"
        return 0
        ;;
      2)
        if [[ "$attempt" -lt 3 ]]; then
          echo "  ...  transient drift in $stack (attempt $attempt/3), retrying..."
          sleep 3
          continue
        fi
        fail "drift detected in $stack (plan wants changes)"
        echo "      see $plan_file"
        grep -E '^(  # |  [-+~]|Plan:|Terraform will)' "$plan_file" | head -n 60 || true
        return 0
        ;;
      *)
        fail "terraform plan failed for $stack (exit $rc)"
        tail -n 40 "$plan_file" >&2 || true
        return 0
        ;;
    esac
  done
}

for stack in shared network backend; do
  check_drift "$stack"
done

# --- summary -----------------------------------------------------------------

echo ""
echo "======== VERIFY SUMMARY ($ENV) ========"
echo "Passed:  $PASS"
echo "Failed:  $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo "Verification FAILED"
  exit 1
fi

echo "Verification PASSED"
exit 0
