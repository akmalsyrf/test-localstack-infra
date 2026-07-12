section "S3 remote state backend"

TFSTATE_BUCKET="tfstate-testinfra-${ENV}"
TFLOCK_TABLE="tflock-testinfra-${ENV}"
if [[ "$TF_BACKEND" == "s3" ]]; then
  if aws_ls s3api head-bucket --bucket "$TFSTATE_BUCKET" >/dev/null 2>&1; then
    ok "tfstate bucket exists ($TFSTATE_BUCKET)"
  else
    fail "tfstate bucket missing ($TFSTATE_BUCKET) but BACKEND=s3"
  fi
  if aws_ls dynamodb describe-table --table-name "$TFLOCK_TABLE" \
    --query 'Table.TableName' --output text 2>/dev/null | grep -qx "$TFLOCK_TABLE"; then
    ok "tflock DynamoDB table exists ($TFLOCK_TABLE)"
  else
    fail "tflock DynamoDB table missing ($TFLOCK_TABLE)"
  fi
  HASH_KEY="$(aws_ls dynamodb describe-table --table-name "$TFLOCK_TABLE" \
    --query 'Table.KeySchema[?KeyType==`HASH`].AttributeName | [0]' --output text 2>/dev/null || true)"
  if [[ "$HASH_KEY" == "LockID" ]]; then
    ok "tflock partition key is LockID"
  else
    fail "tflock partition key unexpected (got ${HASH_KEY:-empty})"
  fi
elif aws_ls s3api head-bucket --bucket "$TFSTATE_BUCKET" >/dev/null 2>&1; then
  ok "tfstate bucket exists ($TFSTATE_BUCKET) (optional; active backend is $TF_BACKEND)"
else
  ok "S3 remote-state bucket not present (active backend=$TF_BACKEND)"
fi
