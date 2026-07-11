resource "aws_secretsmanager_secret" "app" {
  name                    = var.secret_name
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = var.secret_string
}

resource "aws_ssm_parameter" "environment" {
  name  = "/${var.prefix}/environment"
  type  = "String"
  value = "stg"
  tags  = var.tags
}
