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
