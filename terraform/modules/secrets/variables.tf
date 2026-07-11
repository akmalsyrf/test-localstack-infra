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

variable "tags" {
  type    = map(string)
  default = {}
}
