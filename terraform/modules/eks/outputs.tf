output "cluster_name" {
  value = var.cluster_name
}

output "cluster_arn" {
  value = local.cluster_arn
}

output "cluster_endpoint" {
  value = local.kind_endpoint
}

output "cluster_version" {
  value = coalesce(local.kind_version, var.kubernetes_version)
}

output "cluster_status" {
  value = data.external.kind.result.status
}

output "node_group_name" {
  value = local.node_group_name
}

output "node_group_arn" {
  value = local.node_group_arn
}

output "node_group_status" {
  value = data.external.kind.result.status
}

output "cluster_role_arn" {
  value = aws_iam_role.cluster.arn
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "subnet_ids" {
  value = var.subnet_ids
}

output "sample_namespace" {
  value = try(kubernetes_namespace_v1.app[0].metadata[0].name, null)
}

output "sample_service_name" {
  value = try(kubernetes_service_v1.sample[0].metadata[0].name, null)
}

output "sample_node_port" {
  value = try(kubernetes_service_v1.sample[0].spec[0].port[0].node_port, null)
}

output "kind_node_count" {
  value = local.kind_nodes
}
