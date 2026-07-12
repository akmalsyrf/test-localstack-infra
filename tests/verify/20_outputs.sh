section "Terraform backend ready ($TF_BACKEND)"
ensure_stacks_ready_for_outputs

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
require_out STANDARD_QUEUE_ARN backend standard_queue_arn
require_out STANDARD_DLQ_URL backend standard_dlq_url
require_out FIFO_QUEUE_URL backend fifo_queue_url
require_out FIFO_QUEUE_ARN backend fifo_queue_arn
require_out LAMBDA_NAME backend lambda_function_name
require_out API_ID backend api_id
require_out API_URL backend api_invoke_url
require_out OPS_ALERTS_ARN backend ops_alerts_topic_arn
require_out OPS_ALERTS_QUEUE_URL backend ops_alerts_queue_url

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
require_out EKS_WORKLOAD_ROLE eks workload_role_arn
require_out LS_BRIDGE_IP eks localstack_bridge_ip
require_out SMOKE_JOB eks smoke_messaging_job
require_out KIND_NODE_COUNT eks kind_node_count

require_out S3_VPCE_ID network s3_vpc_endpoint_id

if [[ "$FAIL" -gt 0 ]]; then
  echo "Aborting resource checks: terraform outputs incomplete." >&2
  echo "Summary: $PASS passed, $FAIL failed"
  exit 1
fi
