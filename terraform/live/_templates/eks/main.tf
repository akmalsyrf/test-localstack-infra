# Cross-stack inputs: network
# - Local: terraform_remote_state from sibling dirs
# - Terraform Cloud: tfe_outputs from mapped workspaces

data "terraform_remote_state" "network" {
  count   = var.tfc_organization == "" ? 1 : 0
  backend = "local"
  config = {
    path = "${path.module}/../network/terraform.tfstate"
  }
}

data "tfe_outputs" "network" {
  count        = var.tfc_organization != "" ? 1 : 0
  organization = var.tfc_organization
  workspace    = "${var.project_name}-network-${var.environment_slug}"
}

locals {
  network = var.tfc_organization == "" ? data.terraform_remote_state.network[0].outputs : data.tfe_outputs.network[0].values
  # Prefer private subnets (EKS data plane); fall back to public if needed.
  eks_subnet_ids = length(local.network.private_subnet_ids) >= 2 ? slice(local.network.private_subnet_ids, 0, 2) : local.network.public_subnet_ids
  # Shared Kind cluster: unique NodePort per env (see kind/cluster.yaml mappings).
  sample_node_port = var.environment_slug == "dev" ? 30081 : 30080
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

output "kind_cluster_name" {
  value = "testinfra-eks"
}
