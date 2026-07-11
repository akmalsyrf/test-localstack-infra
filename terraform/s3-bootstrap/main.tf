# One-shot bootstrap: S3 bucket + DynamoDB lock table for BACKEND=s3.
# Apply with local state before live stacks use the S3 backend.
# Supported on LocalStack Community (S3 + DynamoDB free-tier).

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "local" {}
}

provider "aws" {
  access_key                  = "test"
  secret_key                  = "test"
  region                      = var.aws_region
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3       = var.localstack_endpoint
    dynamodb = var.localstack_endpoint
    sts      = var.localstack_endpoint
    iam      = var.localstack_endpoint
  }
}

variable "project_name" {
  type    = string
  default = "testinfra"
}

variable "environment_slug" {
  type        = string
  description = "Env slug used in bucket/table names (dev | staging)"
}

variable "aws_region" {
  type    = string
  default = "ap-southeast-3"
}

variable "localstack_endpoint" {
  type    = string
  default = "http://localhost:4566"
}

locals {
  bucket = "tfstate-${var.project_name}-${var.environment_slug}"
  table  = "tflock-${var.project_name}-${var.environment_slug}"
  tags = {
    Terraform   = "true"
    Environment = var.environment_slug
    Project     = var.project_name
    Purpose     = "terraform-remote-state"
  }
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = local.table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = local.tags
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "lock_table" {
  value = aws_dynamodb_table.tflock.name
}

output "aws_region" {
  value = var.aws_region
}

output "localstack_endpoint" {
  value = var.localstack_endpoint
}
