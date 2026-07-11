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

locals {
  prefix = "${var.project_name}-${var.environment}"
  tags = merge(var.tags, {
    Terraform   = "true"
    Environment = var.environment_slug
    Project     = var.project_name
  })
}

variable "vpc_cidr_prefix" {
  type        = string
  description = "First two octets for VPC CIDR, e.g. 10.3 (dev) or 10.1 (staging)"
}
