# EKS stack — S3 remote state (reads network + backend from LocalStack S3).

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket                      = "__TFSTATE_BUCKET__"
    key                         = "network/terraform.tfstate"
    region                      = "__AWS_REGION__"
    # var — not a baked URL: host :4566 can break after Kind attach on Linux CI;
    # scripts/env.sh passes the working endpoint via -var / terraform.tfvars.
    endpoint                    = var.localstack_endpoint
    access_key                  = "test"
    secret_key                  = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}

data "terraform_remote_state" "backend" {
  backend = "s3"
  config = {
    bucket                      = "__TFSTATE_BUCKET__"
    key                         = "backend/terraform.tfstate"
    region                      = "__AWS_REGION__"
    endpoint                    = var.localstack_endpoint
    access_key                  = "test"
    secret_key                  = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}

locals {
  network        = data.terraform_remote_state.network.outputs
  backend        = data.terraform_remote_state.backend.outputs
  eks_subnet_ids = length(local.network.private_subnet_ids) >= 2 ? slice(local.network.private_subnet_ids, 0, 2) : local.network.public_subnet_ids
  # Shared Kind cluster: unique NodePort per env (see kind/cluster.yaml mappings).
  sample_node_port = ({
    "dev"        = 30081
    "staging"    = 30080
    "production" = 30082
  })[var.environment_slug]
}

module "eks" {
  source = "../../../modules/eks"

  prefix                 = local.prefix
  cluster_name           = "${var.project_name}-eks-${var.environment_slug}"
  aws_region             = var.aws_region
  subnet_ids             = local.eks_subnet_ids
  kubeconfig_path        = var.kind_kubeconfig_path
  kind_context           = var.kind_context
  sample_node_port       = local.sample_node_port
  deploy_sample_workload = true
  sns_topic_arn          = local.backend.sns_topic_arn
  sqs_standard_queue_url = local.backend.standard_queue_url
  sqs_fifo_queue_url     = local.backend.fifo_queue_url
  sqs_standard_queue_arn = local.backend.standard_queue_arn
  sqs_fifo_queue_arn     = local.backend.fifo_queue_arn
  enable_irsa_oidc       = false
  tags                   = local.tags
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "cluster_status" {
  value = module.eks.cluster_status
}

output "node_group_name" {
  value = module.eks.node_group_name
}

output "node_group_status" {
  value = module.eks.node_group_status
}

output "sample_namespace" {
  value = module.eks.sample_namespace
}

output "sample_service_name" {
  value = module.eks.sample_service_name
}

output "sample_node_port" {
  value = module.eks.sample_node_port
}

output "cluster_role_arn" {
  value = module.eks.cluster_role_arn
}

output "node_role_arn" {
  value = module.eks.node_role_arn
}

output "workload_role_arn" {
  value = module.eks.workload_role_arn
}

output "localstack_bridge_ip" {
  value = module.eks.localstack_bridge_ip
}

output "smoke_messaging_job" {
  value = module.eks.smoke_messaging_job
}

output "kind_cluster_name" {
  value = "testinfra-eks"
}

output "kind_node_count" {
  value = module.eks.kind_node_count
}
