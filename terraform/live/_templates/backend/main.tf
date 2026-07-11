# Cross-stack inputs: network + shared
# - Local: terraform_remote_state from sibling dirs
# - Terraform Cloud: tfe_outputs from mapped workspaces

data "terraform_remote_state" "network" {
  count   = var.tfc_organization == "" ? 1 : 0
  backend = "local"
  config = {
    path = "${path.module}/../network/terraform.tfstate"
  }
}

data "terraform_remote_state" "shared" {
  count   = var.tfc_organization == "" ? 1 : 0
  backend = "local"
  config = {
    path = "${path.module}/../shared/terraform.tfstate"
  }
}

data "tfe_outputs" "network" {
  count        = var.tfc_organization != "" ? 1 : 0
  organization = var.tfc_organization
  workspace    = "${var.project_name}-network-${var.environment_slug}"
}

data "tfe_outputs" "shared" {
  count        = var.tfc_organization != "" ? 1 : 0
  organization = var.tfc_organization
  workspace    = "${var.project_name}-shared-${var.environment_slug}"
}

locals {
  network = var.tfc_organization == "" ? data.terraform_remote_state.network[0].outputs : data.tfe_outputs.network[0].values
  shared  = var.tfc_organization == "" ? data.terraform_remote_state.shared[0].outputs : data.tfe_outputs.shared[0].values
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "cloudwatch-${var.project_name}-ec2-backend-${var.environment_slug}"
  retention_in_days = 7
  tags              = local.tags
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "backend" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.small"
  subnet_id              = local.network.private_subnet_ids[0]
  vpc_security_group_ids = [local.network.security_group_id]
  iam_instance_profile   = local.shared.instance_profile_name

  tags = merge(local.tags, {
    Name = "ec2-${var.project_name}-backend-${var.environment_slug}"
  })
}

module "messaging" {
  source = "../../../modules/messaging"

  prefix = local.prefix
  tags   = local.tags
}

module "lambda_api" {
  source = "../../../modules/lambda-api"

  prefix          = local.prefix
  stage_name      = var.environment
  lambda_zip_path = "${path.module}/../../../../lambda/api/function.zip"
  environment_variables = {
    SERVICE     = "${var.project_name}-api"
    ENVIRONMENT = var.environment
  }
  tags = local.tags
}

output "instance_id" {
  value = aws_instance.backend.id
}

output "private_ip" {
  value = aws_instance.backend.private_ip
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.backend.name
}

output "sns_topic_arn" {
  value = module.messaging.sns_topic_arn
}

output "standard_queue_url" {
  value = module.messaging.standard_queue_url
}

output "fifo_queue_url" {
  value = module.messaging.fifo_queue_url
}

output "lambda_function_name" {
  value = module.lambda_api.lambda_function_name
}

output "api_id" {
  value = module.lambda_api.api_id
}

output "api_invoke_url" {
  value = module.lambda_api.api_invoke_url
}
