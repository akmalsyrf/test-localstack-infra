output "secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.app.name
}

output "ssm_parameter_name" {
  value = aws_ssm_parameter.environment.name
}
