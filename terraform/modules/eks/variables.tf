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

variable "sns_topic_arn" {
  type        = string
  description = "SNS topic ARN from backend stack (messaging)"
  default     = ""
}

variable "sqs_standard_queue_url" {
  type    = string
  default = ""
}

variable "sqs_fifo_queue_url" {
  type    = string
  default = ""
}

variable "sqs_standard_queue_arn" {
  type    = string
  default = ""
}

variable "sqs_fifo_queue_arn" {
  type    = string
  default = ""
}

variable "enable_irsa_oidc" {
  type        = bool
  description = "Enable real EKS OIDC/IRSA trust (no-op on LocalStack Community; default false)."
  default     = false
}

variable "oidc_provider_arn" {
  type    = string
  default = ""
}

variable "oidc_issuer_host" {
  type    = string
  default = ""
}

variable "localstack_container_name" {
  type    = string
  default = "testinfra-localstack"
}
