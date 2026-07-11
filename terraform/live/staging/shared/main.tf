# Shared / platform resources: S3, Secrets, IAM

module "s3_app_data" {
  source = "./modules/s3-bucket"

  bucket = "${var.project_name}-app-data-${var.environment_slug}"
  tags   = local.tags
}

module "s3_ec2_backend" {
  source = "./modules/s3-bucket"

  bucket = "${var.project_name}-ec2-backend-${var.environment_slug}"
  tags   = local.tags
}

module "secrets" {
  source = "./modules/secrets"

  prefix      = local.prefix
  secret_name = "${var.project_name}/app/api/env/${var.environment}"
  tags        = local.tags
}

locals {
  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = module.secrets.secret_arn
      },
      {
        Sid    = "AllowS3BackendRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          module.s3_ec2_backend.bucket_arn,
          "${module.s3_ec2_backend.bucket_arn}/*"
        ]
      },
      {
        Sid    = "AllowCloudWatchLogsStreaming"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups"
        ]
        Resource = ["*"]
      }
    ]
  })
}

module "iam_ec2_backend" {
  source = "./modules/iam-ec2-backend"

  role_name   = "role-${var.project_name}-session-manager-be-${var.environment_slug}"
  policy_name = "policy-${var.project_name}-ec2-backend-${var.environment_slug}"
  policy_json = local.policy_json
  tags        = local.tags
}

output "app_data_bucket_id" {
  value = module.s3_app_data.bucket_id
}

output "app_data_bucket_arn" {
  value = module.s3_app_data.bucket_arn
}

output "ec2_backend_bucket_id" {
  value = module.s3_ec2_backend.bucket_id
}

output "ec2_backend_bucket_arn" {
  value = module.s3_ec2_backend.bucket_arn
}

output "secret_arn" {
  value = module.secrets.secret_arn
}

output "secret_name" {
  value = module.secrets.secret_name
}

output "instance_profile_name" {
  value = module.iam_ec2_backend.instance_profile_name
}

output "role_name" {
  value = module.iam_ec2_backend.role_name
}

output "policy_arn" {
  value = module.iam_ec2_backend.policy_arn
}
