# Backend stack — S3 remote state (reads sibling stack state from LocalStack S3).
# Placeholders tfstate-testinfra-dev / ap-southeast-3 injected by sync-live.sh.
# Remote-state endpoint uses var.localstack_endpoint (not a baked URL) so Kind
# attach breaking host :4566 on Linux CI can be fixed via -var / tfvars.

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket                      = "tfstate-testinfra-dev"
    key                         = "network/terraform.tfstate"
    region                      = "ap-southeast-3"
    endpoint                    = var.localstack_endpoint
    access_key                  = "test"
    secret_key                  = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket                      = "tfstate-testinfra-dev"
    key                         = "shared/terraform.tfstate"
    region                      = "ap-southeast-3"
    endpoint                    = var.localstack_endpoint
    access_key                  = "test"
    secret_key                  = "test"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}

locals {
  network = data.terraform_remote_state.network.outputs
  shared  = data.terraform_remote_state.shared.outputs
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "cloudwatch-${var.project_name}-ec2-backend-${var.environment_slug}"
  retention_in_days = var.log_retention_days
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
  source = "./modules/messaging"

  prefix = local.prefix
}

module "lambda_api" {
  source = "./modules/lambda-api"

  prefix          = local.prefix
  stage_name      = var.environment
  lambda_zip_path = "${path.module}/lambda/function.zip"
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

# Subscriber for ops_alerts so alarms are not fire-and-forget.
# Swap this SQS subscription for a real email/Slack/PagerDuty endpoint when moving
# off LocalStack — SQS is used here because external delivery can't be verified
# in this environment.
resource "aws_sqs_queue" "ops_alerts_queue" {
  name                      = "${local.prefix}-ops-alerts"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  depends_on = [aws_sns_topic.ops_alerts]
}

resource "aws_sqs_queue_policy" "ops_alerts_queue" {
  queue_url = aws_sqs_queue.ops_alerts_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSNSPublish"
      Effect    = "Allow"
      Principal = "*"
      Action    = "SQS:SendMessage"
      Resource  = aws_sqs_queue.ops_alerts_queue.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.ops_alerts.arn }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "ops_alerts_to_queue" {
  topic_arn            = aws_sns_topic.ops_alerts.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.ops_alerts_queue.arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.ops_alerts_queue]
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
  threshold           = var.sqs_depth_alarm_threshold
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

output "standard_queue_arn" {
  value = module.messaging.standard_queue_arn
}

output "standard_dlq_url" {
  value = module.messaging.standard_dlq_url
}

output "fifo_queue_url" {
  value = module.messaging.fifo_queue_url
}

output "fifo_queue_arn" {
  value = module.messaging.fifo_queue_arn
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

output "ops_alerts_queue_url" {
  value = aws_sqs_queue.ops_alerts_queue.url
}
