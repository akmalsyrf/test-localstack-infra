#!/usr/bin/env bash
# Comprehensive post-apply verification against LocalStack (+ Kind/EKS).
# Usage: verify-apply.sh <dev|staging>
# Compatible with Bash 3.2+ (macOS /bin/bash) and Bash 4+/5 (CI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="${1:-}"
ENDPOINT="${LOCALSTACK_ENDPOINT:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-3}"
KIND_KUBECONFIG="${KIND_KUBECONFIG:-$ROOT/.kube/kind-config}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-testinfra-eks}"

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

# Expected naming / CIDR by environment (infra "truths")
case "$ENV" in
  staging)
    EXPECT_ENV_SHORT="stg"
    EXPECT_VPC_CIDR="10.1.0.0/16"
    EXPECT_CIDR_PREFIX="10.1"
    ;;
  dev)
    EXPECT_ENV_SHORT="dev"
    EXPECT_VPC_CIDR="10.3.0.0/16"
    EXPECT_CIDR_PREFIX="10.3"
    ;;
  *)
    echo "Unknown environment: $ENV" >&2
    exit 1
    ;;
esac
EXPECT_PREFIX="testinfra-${EXPECT_ENV_SHORT}"

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
echo "Expected prefix:     $EXPECT_PREFIX"
echo "Expected VPC CIDR:   $EXPECT_VPC_CIDR"

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
require_out IGW_ID network igw_id

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

require_out EKS_CLUSTER_NAME eks cluster_name
require_out EKS_CLUSTER_ARN eks cluster_arn
require_out EKS_CLUSTER_STATUS eks cluster_status
require_out EKS_NODE_GROUP eks node_group_name
require_out EKS_CLUSTER_ROLE eks cluster_role_arn
require_out EKS_NODE_ROLE eks node_role_arn
require_out EKS_SAMPLE_NS eks sample_namespace
require_out EKS_SAMPLE_SVC eks sample_service_name
require_out EKS_NODE_PORT eks sample_node_port
require_out KIND_NAME eks kind_cluster_name

if [[ "$FAIL" -gt 0 ]]; then
  echo "Aborting resource checks: terraform outputs incomplete." >&2
  echo "Summary: $PASS passed, $FAIL failed"
  exit 1
fi

# --- naming / config truths --------------------------------------------------

section "Naming & config truths"

if [[ "$APP_DATA_BUCKET" == "testinfra-app-data-${ENV}" ]]; then
  ok "app-data bucket name matches convention ($APP_DATA_BUCKET)"
else
  fail "app-data bucket name unexpected ($APP_DATA_BUCKET)"
fi

if [[ "$EC2_BACKEND_BUCKET" == "testinfra-ec2-backend-${ENV}" ]]; then
  ok "ec2-backend bucket name matches convention ($EC2_BACKEND_BUCKET)"
else
  fail "ec2-backend bucket name unexpected ($EC2_BACKEND_BUCKET)"
fi

if [[ "$SECRET_NAME" == "testinfra/app/api/env/${EXPECT_ENV_SHORT}" ]]; then
  ok "secret name matches convention ($SECRET_NAME)"
else
  fail "secret name unexpected ($SECRET_NAME)"
fi

if [[ "$ROLE_NAME" == "role-testinfra-session-manager-be-${ENV}" ]]; then
  ok "IAM role name matches convention ($ROLE_NAME)"
else
  fail "IAM role name unexpected ($ROLE_NAME)"
fi

if [[ "$LOG_GROUP" == "cloudwatch-testinfra-ec2-backend-${ENV}" ]]; then
  ok "log group name matches convention ($LOG_GROUP)"
else
  fail "log group name unexpected ($LOG_GROUP)"
fi

if [[ "$LAMBDA_NAME" == "${EXPECT_PREFIX}-api" ]]; then
  ok "Lambda name matches convention ($LAMBDA_NAME)"
else
  fail "Lambda name unexpected ($LAMBDA_NAME)"
fi

if [[ "$EKS_CLUSTER_NAME" == "testinfra-eks-${ENV}" ]]; then
  ok "EKS cluster name matches convention ($EKS_CLUSTER_NAME)"
else
  fail "EKS cluster name unexpected ($EKS_CLUSTER_NAME)"
fi

if [[ "$VPC_CIDR" == "$EXPECT_VPC_CIDR" ]]; then
  ok "VPC CIDR matches env truth ($VPC_CIDR)"
else
  fail "VPC CIDR mismatch (expected $EXPECT_VPC_CIDR, got $VPC_CIDR)"
fi

if [[ "$KIND_NAME" == "$KIND_CLUSTER_NAME" ]]; then
  ok "Kind cluster name matches ($KIND_NAME)"
else
  fail "Kind cluster name mismatch (expected $KIND_CLUSTER_NAME, got $KIND_NAME)"
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

# Public access block truths
PAB="$(aws_ls s3api get-public-access-block --bucket "$APP_DATA_BUCKET" --output json 2>/dev/null || echo '{}')"
if echo "$PAB" | python3 -c '
import json,sys
c=(json.load(sys.stdin).get("PublicAccessBlockConfiguration") or {})
sys.exit(0 if all(c.get(k) is True for k in (
  "BlockPublicAcls","IgnorePublicAcls","BlockPublicPolicy","RestrictPublicBuckets")) else 1)
'; then
  ok "S3 app-data public access block fully enabled"
else
  fail "S3 app-data public access block incomplete"
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
  if echo "$SECRET_VAL" | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
sys.exit(0 if isinstance(d, dict) and len(d)>0 else 1)
' 2>/dev/null; then
    ok "secret payload is non-empty JSON object"
  else
    fail "secret payload is not valid JSON object"
  fi
else
  fail "Secrets Manager GetSecretValue failed"
fi

if aws_ls iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  ok "IAM role exists ($ROLE_NAME)"
else
  fail "IAM role missing ($ROLE_NAME)"
fi

ASSUME="$(aws_ls iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo '{}')"
if echo "$ASSUME" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
# AWS may return already-decoded dict or URL-encoded string via CLI; normalize
if isinstance(doc, str):
  doc=json.loads(doc)
stmts=doc.get("Statement") or []
ok=False
for s in stmts:
  p=s.get("Principal") or {}
  svc=p.get("Service")
  if svc=="ec2.amazonaws.com" or (isinstance(svc,list) and "ec2.amazonaws.com" in svc):
    ok=True
sys.exit(0 if ok else 1)
'; then
  ok "IAM role trusts ec2.amazonaws.com"
else
  fail "IAM role trust policy missing ec2.amazonaws.com"
fi

if aws_ls iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
  ok "IAM instance profile exists ($INSTANCE_PROFILE)"
else
  fail "IAM instance profile missing ($INSTANCE_PROFILE)"
fi

PROFILE_ROLE="$(aws_ls iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || true)"
if [[ "$PROFILE_ROLE" == "$ROLE_NAME" ]]; then
  ok "instance profile bound to expected role"
else
  fail "instance profile role mismatch (got ${PROFILE_ROLE:-empty})"
fi

if aws_ls iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  ok "IAM policy exists ($POLICY_ARN)"
else
  fail "IAM policy missing ($POLICY_ARN)"
fi

# --- network stack -----------------------------------------------------------

section "Network stack (VPC / subnets / SG / IGW)"

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

DNS_SUPPORT="$(aws_ls ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsSupport \
  --query 'EnableDnsSupport.Value' --output text 2>/dev/null || true)"
DNS_HOSTNAMES="$(aws_ls ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute enableDnsHostnames \
  --query 'EnableDnsHostnames.Value' --output text 2>/dev/null || true)"
if [[ "$DNS_SUPPORT" == "True" || "$DNS_SUPPORT" == "true" ]]; then
  ok "VPC DNS support enabled"
else
  fail "VPC DNS support disabled (got ${DNS_SUPPORT:-empty})"
fi
if [[ "$DNS_HOSTNAMES" == "True" || "$DNS_HOSTNAMES" == "true" ]]; then
  ok "VPC DNS hostnames enabled"
else
  fail "VPC DNS hostnames disabled (got ${DNS_HOSTNAMES:-empty})"
fi

if [[ -n "$IGW_ID" ]] && aws_ls ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" \
  --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null | grep -qx "$IGW_ID"; then
  ok "Internet Gateway exists ($IGW_ID)"
else
  fail "Internet Gateway missing ($IGW_ID)"
fi

IGW_VPC="$(aws_ls ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" \
  --query "InternetGateways[0].Attachments[0].VpcId" --output text 2>/dev/null || true)"
if [[ "$IGW_VPC" == "$VPC_ID" ]]; then
  ok "IGW attached to VPC"
else
  fail "IGW not attached to VPC (got ${IGW_VPC:-empty})"
fi

PUBLIC_COUNT="$(echo "$PUBLIC_SUBNETS_JSON" | json_list_len)"
PRIVATE_COUNT="$(echo "$PRIVATE_SUBNETS_JSON" | json_list_len)"

if [[ "$PUBLIC_COUNT" -eq 3 ]]; then
  ok "public subnet count is 3"
else
  fail "public subnet count expected 3, got $PUBLIC_COUNT"
fi

if [[ "$PRIVATE_COUNT" -eq 3 ]]; then
  ok "private subnet count is 3"
else
  fail "private subnet count expected 3, got $PRIVATE_COUNT"
fi

if [[ "$PUBLIC_COUNT" -ge 1 ]]; then
  # shellcheck disable=SC2046
  if aws_ls ec2 describe-subnets --subnet-ids $(echo "$PUBLIC_SUBNETS_JSON" | json_list_lines | tr '\n' ' ') \
    --query "length(Subnets)" --output text 2>/dev/null | grep -qx "$PUBLIC_COUNT"; then
    ok "public subnets exist ($PUBLIC_COUNT)"
  else
    fail "public subnets missing or incomplete"
  fi

  # shellcheck disable=SC2046
  PUB_MAP="$(aws_ls ec2 describe-subnets --subnet-ids $(echo "$PUBLIC_SUBNETS_JSON" | json_list_lines | tr '\n' ' ') \
    --query "Subnets[].MapPublicIpOnLaunch" --output json 2>/dev/null || echo '[]')"
  if echo "$PUB_MAP" | python3 -c 'import json,sys; vals=json.load(sys.stdin); sys.exit(0 if vals and all(v is True for v in vals) else 1)'; then
    ok "public subnets MapPublicIpOnLaunch=true"
  else
    fail "public subnets MapPublicIpOnLaunch not all true"
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

  # shellcheck disable=SC2046
  PRIV_MAP="$(aws_ls ec2 describe-subnets --subnet-ids $(echo "$PRIVATE_SUBNETS_JSON" | json_list_lines | tr '\n' ' ') \
    --query "Subnets[].MapPublicIpOnLaunch" --output json 2>/dev/null || echo '[]')"
  if echo "$PRIV_MAP" | python3 -c 'import json,sys; vals=json.load(sys.stdin); sys.exit(0 if vals and all(v is False for v in vals) else 1)'; then
    ok "private subnets MapPublicIpOnLaunch=false"
  else
    fail "private subnets MapPublicIpOnLaunch not all false"
  fi
else
  fail "private_subnet_ids empty"
fi

# CIDR layout truths from network module
# shellcheck disable=SC2046
ALL_CIDRS="$(aws_ls ec2 describe-subnets --subnet-ids \
  $(echo "$PUBLIC_SUBNETS_JSON" | json_list_lines | tr '\n' ' ') \
  $(echo "$PRIVATE_SUBNETS_JSON" | json_list_lines | tr '\n' ' ') \
  --query "Subnets[].CidrBlock" --output json 2>/dev/null || echo '[]')"
if echo "$ALL_CIDRS" | python3 -c '
import json,sys
prefix=sys.argv[1]
cidrs=set(json.load(sys.stdin))
want={f"{prefix}.{i}.0/24" for i in (0,1,2,3,4,5)}
sys.exit(0 if cidrs==want else 1)
' "$EXPECT_CIDR_PREFIX"; then
  ok "subnet CIDRs match expected /24 layout for $EXPECT_CIDR_PREFIX"
else
  fail "subnet CIDR layout unexpected: $ALL_CIDRS"
fi

if aws_ls ec2 describe-security-groups --group-ids "$SG_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -qx "$SG_ID"; then
  ok "security group exists ($SG_ID)"
else
  fail "security group missing ($SG_ID)"
fi

SG_VPC="$(aws_ls ec2 describe-security-groups --group-ids "$SG_ID" \
  --query "SecurityGroups[0].VpcId" --output text 2>/dev/null || true)"
if [[ "$SG_VPC" == "$VPC_ID" ]]; then
  ok "security group in correct VPC"
else
  fail "security group VPC mismatch (got ${SG_VPC:-empty})"
fi

SG_JSON="$(aws_ls ec2 describe-security-groups --group-ids "$SG_ID" --output json 2>/dev/null || echo '{}')"
if echo "$SG_JSON" | python3 -c '
import json,sys
sg=(json.load(sys.stdin).get("SecurityGroups") or [{}])[0]
ingress=sg.get("IpPermissions") or []
ports=set()
for r in ingress:
  if r.get("IpProtocol")=="tcp":
    ports.add(r.get("FromPort"))
sys.exit(0 if 443 in ports and 3000 in ports else 1)
'; then
  ok "SG ingress allows TCP 443 and 3000"
else
  fail "SG ingress missing 443 and/or 3000"
fi

if echo "$SG_JSON" | python3 -c '
import json,sys
sg=(json.load(sys.stdin).get("SecurityGroups") or [{}])[0]
egress=sg.get("IpPermissionsEgress") or []
sys.exit(0 if any(r.get("IpProtocol") in ("-1","all") for r in egress) or len(egress)>0 else 1)
'; then
  ok "SG has egress rules"
else
  fail "SG egress missing"
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
if [[ "$RETENTION" == "7" ]]; then
  ok "log group retention is 7 days"
else
  # LocalStack may omit retention; warn as soft fail only if empty
  if [[ -z "$RETENTION" || "$RETENTION" == "None" || "$RETENTION" == "null" ]]; then
    ok "log group retention not reported by LocalStack (acceptable)"
  else
    fail "log group retention unexpected (got $RETENTION)"
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

if [[ "$API_URL" == *"/restapis/${API_ID}/${EXPECT_ENV_SHORT}/_user_request_/"* ]]; then
  ok "API invoke URL shape matches LocalStack convention"
else
  fail "API invoke URL unexpected ($API_URL)"
fi

# --- EKS mirror / Kind -------------------------------------------------------

section "EKS mirror (IAM on LocalStack) + Kind"

if [[ "$EKS_CLUSTER_STATUS" == "ACTIVE" ]]; then
  ok "mirrored EKS cluster status=ACTIVE"
else
  fail "mirrored EKS cluster status unexpected ($EKS_CLUSTER_STATUS)"
fi

if [[ "$EKS_CLUSTER_ARN" == "arn:aws:eks:${REGION}:000000000000:cluster/${EKS_CLUSTER_NAME}" ]]; then
  ok "mirrored EKS cluster ARN shape"
else
  fail "mirrored EKS cluster ARN unexpected ($EKS_CLUSTER_ARN)"
fi

CLUSTER_ROLE_NAME="${EXPECT_PREFIX}-eks-cluster"
NODE_ROLE_NAME="${EXPECT_PREFIX}-eks-node"
if aws_ls iam get-role --role-name "$CLUSTER_ROLE_NAME" >/dev/null 2>&1; then
  ok "EKS cluster IAM role exists ($CLUSTER_ROLE_NAME)"
else
  fail "EKS cluster IAM role missing ($CLUSTER_ROLE_NAME)"
fi
if aws_ls iam get-role --role-name "$NODE_ROLE_NAME" >/dev/null 2>&1; then
  ok "EKS node IAM role exists ($NODE_ROLE_NAME)"
else
  fail "EKS node IAM role missing ($NODE_ROLE_NAME)"
fi

CLUSTER_TRUST="$(aws_ls iam get-role --role-name "$CLUSTER_ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || echo '{}')"
if echo "$CLUSTER_TRUST" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
if isinstance(doc, str):
  doc=json.loads(doc)
ok=False
for s in doc.get("Statement") or []:
  svc=(s.get("Principal") or {}).get("Service")
  if svc=="eks.amazonaws.com" or (isinstance(svc,list) and "eks.amazonaws.com" in svc):
    ok=True
sys.exit(0 if ok else 1)
'; then
  ok "cluster role trusts eks.amazonaws.com"
else
  fail "cluster role trust policy missing eks.amazonaws.com"
fi

if [[ "$EKS_NODE_GROUP" == "${EXPECT_PREFIX}-ng" ]]; then
  ok "mirrored node group name ($EKS_NODE_GROUP)"
else
  fail "mirrored node group name unexpected ($EKS_NODE_GROUP)"
fi

if command -v kind >/dev/null 2>&1 || [[ -x "$ROOT/bin/kind" ]]; then
  KIND_BIN="$(command -v kind 2>/dev/null || true)"
  [[ -z "$KIND_BIN" && -x "$ROOT/bin/kind" ]] && KIND_BIN="$ROOT/bin/kind"
  if "$KIND_BIN" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    ok "Kind cluster exists ($KIND_CLUSTER_NAME)"
  else
    fail "Kind cluster missing ($KIND_CLUSTER_NAME)"
  fi
else
  fail "kind binary not found"
fi

if [[ -f "$KIND_KUBECONFIG" ]] && command -v kubectl >/dev/null 2>&1; then
  if kubectl --kubeconfig "$KIND_KUBECONFIG" get nodes --no-headers 2>/dev/null | grep -q Ready; then
    ok "Kind nodes are Ready"
  else
    fail "Kind nodes not Ready"
  fi

  MIRROR_CM="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n default \
    get configmap "eks-mirror-${EKS_CLUSTER_NAME}" -o jsonpath='{.data.provider}' 2>/dev/null || true)"
  if [[ "$MIRROR_CM" == "kind" ]]; then
    ok "eks-mirror ConfigMap present (provider=kind)"
  else
    fail "eks-mirror ConfigMap missing or unexpected"
  fi

  READY_PODS="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get deploy sample-nginx -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ "${READY_PODS:-0}" -ge 1 ]]; then
    ok "sample-nginx deployment ready in $EKS_SAMPLE_NS"
  else
    fail "sample-nginx deployment not ready (readyReplicas=${READY_PODS:-empty})"
  fi

  SVC_PORT="$(kubectl --kubeconfig "$KIND_KUBECONFIG" -n "$EKS_SAMPLE_NS" \
    get svc "$EKS_SAMPLE_SVC" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ "$SVC_PORT" == "$EKS_NODE_PORT" ]]; then
    ok "sample Service NodePort matches output ($SVC_PORT)"
  else
    fail "sample Service NodePort mismatch (expected $EKS_NODE_PORT, got ${SVC_PORT:-empty})"
  fi

  if curl -sf --max-time 15 "http://127.0.0.1:${EKS_NODE_PORT}/" | grep -qi nginx; then
    ok "Kind NodePort smoke (nginx via :$EKS_NODE_PORT)"
  else
    fail "Kind NodePort smoke failed (http://127.0.0.1:${EKS_NODE_PORT}/)"
  fi
else
  fail "kubectl or Kind kubeconfig missing for workload checks"
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

for stack in shared network backend eks; do
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
