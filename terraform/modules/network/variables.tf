variable "project_name" {
  type    = string
  default = "testinfra"
}

variable "environment" {
  type    = string
  default = "stg"
}

variable "vpc_cidr_prefix" {
  type        = string
  description = "First two octets, e.g. 10.1 for staging"
  default     = "10.1"
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-southeast-3a", "ap-southeast-3b", "ap-southeast-3c"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
