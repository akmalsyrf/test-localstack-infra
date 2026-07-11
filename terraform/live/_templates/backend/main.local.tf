# Backend stack — local state only (reads sibling terraform.tfstate files).
# No tfe provider / tfe_outputs (those are in main.tf for BACKEND=cloud).
#
# ASG+launch_template self-healing: LocalStack Community implements Auto Scaling
# APIs, but ALB target-group health-check simulation is incomplete and swapping
# the single aws_instance for ASG would break existing instance_id verify paths.
# Kept as a single EC2 instance with IMDSv2 + encrypted root volume instead.

data "terraform_remote_state" "network" {
  backend = "local"
  config = {
    path = "${path.module}/../network/terraform.tfstate"
  }
}

data "terraform_remote_state" "shared" {
  backend = "local"
  config = {
    path = "${path.module}/../shared/terraform.tfstate"
  }
}

locals {
  network = data.terraform_remote_state.network.outputs
  shared  = data.terraform_remote_state.shared.outputs
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "cloudwatch-${var.project_name}-ec2-backend-${var.environment_slug}"
  retention_in_days = 14
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

  # Enforce IMDSv2 (LocalStack Community supports metadata_options on EC2).
  metadata_options {
    http_tokens = "required"
  }

  # EBS encryption with AWS-managed key (no custom KMS — free-tier safe).
  # volume_size required: LocalStack RunInstances rejects encrypted root without size/snapshotId.
  root_block_device {
    volume_size = 8
    encrypted   = true
  }

  tags = merge(local.tags, {
    Name = "ec2-${var.project_name}-backend-${var.environment_slug}"
  })

  lifecycle {
    # LocalStack accepts metadata_options on RunInstances but omits them on
    # DescribeInstances → perpetual +metadata_options drift without ignore.
    ignore_changes = [tags, tags_all, metadata_options]
  }
}

module "messaging" {
  source = "../../../modules/messaging"

  prefix = local.prefix
}

module "lambda_api" {
  source = "../../../modules/lambda-api"

  prefix          = local.prefix
  stage_name      = var.environment
  lambda_zip_path = "${path.module}/../../../../lambda/api/function.zip"
  dlq_arn         = module.messaging.standard_dlq_arn
  environment_variables = {
    SERVICE     = "${var.project_name}-api"
    ENVIRONMENT = var.environment
  }
  tags = local.tags
}

# Ops alerts topic + CloudWatch alarms (EC2 / Lambda / SQS depth).
resource "aws_sns_topic" "ops_alerts" {
  name = "${local.prefix}-ops-alerts"
}

resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  alarm_name          = "${local.prefix}-ec2-status-check-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "EC2 instance status check failed"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]

  dimensions = {
    InstanceId = aws_instance.backend.id
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.prefix}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Lambda function errors"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]

  dimensions = {
    FunctionName = module.lambda_api.lambda_function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "sqs_depth" {
  alarm_name          = "${local.prefix}-sqs-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 100
  alarm_description   = "SQS standard queue depth high"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]

  dimensions = {
    QueueName = module.messaging.standard_queue_name
  }
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

output "standard_dlq_url" {
  value = module.messaging.standard_dlq_url
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

output "ops_alerts_topic_arn" {
  value = aws_sns_topic.ops_alerts.arn
}
