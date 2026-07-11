variable "role_name" {
  type = string
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace of the workload ServiceAccount (IRSA sub claim)"
}

variable "service_account_name" {
  type    = string
  default = "workload"
}

variable "enable_irsa_oidc" {
  type        = bool
  description = "Wire real EKS OIDC trust. Default false on LocalStack/Kind (no real EKS API)."
  default     = false
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS OIDC provider ARN for IRSA (used when enable_irsa_oidc=true)."
  default     = ""
}

variable "oidc_issuer_host" {
  type        = string
  description = "OIDC issuer host without https:// (e.g. oidc.eks.region.amazonaws.com/id/EXAMPLED). Required when enable_irsa_oidc=true."
  default     = ""
}

variable "sns_topic_arn" {
  type = string
}

variable "sqs_standard_queue_arn" {
  type = string
}

variable "sqs_fifo_queue_arn" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
