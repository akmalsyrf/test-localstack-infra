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

# S3 Gateway VPC endpoint
if [[ -n "$S3_VPCE_ID" ]] && aws_ls ec2 describe-vpc-endpoints --vpc-endpoint-ids "$S3_VPCE_ID" \
  --query "VpcEndpoints[0].VpcEndpointId" --output text 2>/dev/null | grep -qx "$S3_VPCE_ID"; then
  ok "S3 Gateway VPC endpoint exists ($S3_VPCE_ID)"
else
  fail "S3 Gateway VPC endpoint missing ($S3_VPCE_ID)"
fi

VPCE_TYPE="$(aws_ls ec2 describe-vpc-endpoints --vpc-endpoint-ids "$S3_VPCE_ID" \
  --query "VpcEndpoints[0].VpcEndpointType" --output text 2>/dev/null || true)"
if [[ "$VPCE_TYPE" == "Gateway" ]]; then
  ok "VPC endpoint type is Gateway"
else
  fail "VPC endpoint type unexpected (got ${VPCE_TYPE:-empty})"
fi

VPCE_SVC="$(aws_ls ec2 describe-vpc-endpoints --vpc-endpoint-ids "$S3_VPCE_ID" \
  --query "VpcEndpoints[0].ServiceName" --output text 2>/dev/null || true)"
if [[ "$VPCE_SVC" == *"s3"* ]]; then
  ok "VPC endpoint service is S3 ($VPCE_SVC)"
else
  fail "VPC endpoint service unexpected (got ${VPCE_SVC:-empty})"
fi
