variable "prefix" {
  type = string
}

variable "stage_name" {
  type    = string
  default = "stg"
}

variable "lambda_zip_path" {
  type = string
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "dlq_arn" {
  type        = string
  description = "SQS DLQ ARN for Lambda async failure capture (empty = no DLQ)"
  default     = ""
}

variable "reserved_concurrent_executions" {
  type        = number
  description = "Cap concurrent Lambda executions to avoid starving other workloads"
  default     = 10
}

variable "throttling_burst_limit" {
  type    = number
  default = 20
}

variable "throttling_rate_limit" {
  type    = number
  default = 10
}

variable "tags" {
  type    = map(string)
  default = {}
}
