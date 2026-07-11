# Shared / network stacks — Terraform Cloud remote state, local execution.
# Workspace name is injected by scripts/sync-live.sh

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  cloud {
    organization = "ExperimentTerraform"

    workspaces {
      name = "testinfra-shared-staging"
    }
  }
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
    apigateway     = var.localstack_endpoint
    cloudwatch     = var.localstack_endpoint
    logs           = var.localstack_endpoint
    ec2            = var.localstack_endpoint
    iam            = var.localstack_endpoint
    lambda         = var.localstack_endpoint
    s3             = var.localstack_endpoint
    secretsmanager = var.localstack_endpoint
    sns            = var.localstack_endpoint
    sqs            = var.localstack_endpoint
    ssm            = var.localstack_endpoint
    sts            = var.localstack_endpoint
  }
}
