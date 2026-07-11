variable "prefix" {
  type = string
}

variable "secret_name" {
  type = string
}

variable "secret_string" {
  type      = string
  sensitive = true
  default   = "{\"ENVIRONMENT\":\"stg\",\"SOURCE\":\"localstack\"}"
}

variable "recovery_window_in_days" {
  type        = number
  description = "Days before permanent deletion on destroy (0 = force delete). LocalStack free supports this; automatic rotation Lambda is Pro/limited — skipped."
  default     = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
