# Kind-backed EKS mirror (LocalStack free).
#
# LocalStack community returns "API for service 'eks' not yet implemented or pro".
# This module mirrors the usual LocalStack/AWS EKS Terraform shape:
#   IAM cluster role + node role  →  cluster registration  →  node group  →  workloads
# but the control plane is Kind (see scripts/kind-up.sh + kind/cluster.yaml).
# Outputs intentionally match aws_eks_cluster / aws_eks_node_group fields.

data "aws_iam_policy_document" "eks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.prefix}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
  tags               = var.tags
}

# LocalStack free often lacks AWS managed EKS policies; inline equivalents.
resource "aws_iam_role_policy" "cluster" {
  name = "${var.prefix}-eks-cluster"
  role = aws_iam_role.cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:Describe*",
        "eks:*",
        "iam:GetRole",
        "iam:ListAttachedRolePolicies"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "node" {
  name               = "${var.prefix}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "node" {
  name = "${var.prefix}-eks-node"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:Describe*",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ]
      Resource = "*"
    }]
  })
}

# Discover Kind control plane (mirrors describe-cluster becoming ACTIVE).
data "external" "kind" {
  program = ["bash", "${path.module}/scripts/kind-info.sh"]

  query = {
    kubeconfig   = var.kubeconfig_path
    cluster_name = var.kind_cluster_name
    context      = var.kind_context
  }
}

# Discover how Kind pods reach LocalStack :4566 (host.docker.internal preferred;
# see scripts/localstack-network-info.sh). Avoids attaching LS to the kind network.
data "external" "localstack_network" {
  program = ["bash", "${path.module}/scripts/localstack-network-info.sh"]

  query = {
    container_name = var.localstack_container_name
    cluster_name   = var.kind_cluster_name
  }
}

locals {
  kind_endpoint = data.external.kind.result.endpoint
  kind_version  = data.external.kind.result.version
  kind_nodes    = tonumber(data.external.kind.result.node_count)
  # Synthetic EKS-compatible identifiers (LocalStack Pro would return these via AWS API).
  cluster_arn     = "arn:aws:eks:${var.aws_region}:000000000000:cluster/${var.cluster_name}"
  node_group_name = "${var.prefix}-ng"
  node_group_arn  = "arn:aws:eks:${var.aws_region}:000000000000:nodegroup/${var.cluster_name}/${local.node_group_name}/kind"
}
