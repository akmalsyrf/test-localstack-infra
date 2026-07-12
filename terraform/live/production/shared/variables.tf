variable "project_name" {
  type    = string
  default = "testinfra"
}

variable "environment" {
  type        = string
  description = "Short env code used in resource names (dev | stg)"
}

variable "environment_slug" {
  type        = string
  description = "Env slug used in TFC workspace names (dev | staging)"
}

variable "aws_region" {
  type    = string
  default = "ap-southeast-3"
}

variable "localstack_endpoint" {
  type    = string
  default = "http://localhost:4566"
}

variable "tfc_organization" {
  type        = string
  description = "Set to your TFC org to read cross-stack state via tfe_outputs. Empty = local terraform_remote_state."
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "kind_kubeconfig_path" {
  type        = string
  description = "Path to Kind kubeconfig for the kubernetes provider (EKS sample workload)"
  default     = ""
}

variable "kind_context" {
  type        = string
  description = "kubectl context name for the Kind cluster"
  default     = "kind-testinfra-eks"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention for backend EC2 log group (production uses longer)"
  default     = 14
}

variable "sqs_depth_alarm_threshold" {
  type        = number
  description = "CloudWatch alarm threshold for SQS ApproximateNumberOfMessagesVisible"
  default     = 100
}

variable "secret_recovery_window_days" {
  type        = number
  description = "Secrets Manager recovery window (production uses longer to reduce accidental loss)"
  default     = 7
}

locals {
  prefix = "${var.project_name}-${var.environment}"
  tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment_slug
    Project     = var.project_name
  })
}
