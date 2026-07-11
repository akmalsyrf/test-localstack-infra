variable "prefix" {
  type        = string
  description = "Resource name prefix (e.g. testinfra-stg)"
}

variable "cluster_name" {
  type        = string
  description = "Logical EKS cluster name (mirrored onto Kind)"
}

variable "aws_region" {
  type    = string
  default = "ap-southeast-3"
}

variable "kubernetes_version" {
  type        = string
  description = "Advertised Kubernetes version (informational; Kind supplies the real version)"
  default     = "1.29"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs that would attach to a real EKS cluster (recorded in tags/outputs)"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "deploy_sample_workload" {
  type        = bool
  description = "Deploy sample nginx Deployment/Service onto the Kind cluster"
  default     = true
}

variable "sample_replicas" {
  type    = number
  default = 2
}

variable "sample_node_port" {
  type        = number
  description = "NodePort for sample Service (unique per env on the shared Kind cluster)"
  default     = 30080
}

variable "kubeconfig_path" {
  type        = string
  description = "Path to Kind kubeconfig used by the kubernetes provider + kind-info"
}

variable "kind_cluster_name" {
  type    = string
  default = "testinfra-eks"
}

variable "kind_context" {
  type    = string
  default = "kind-testinfra-eks"
}
