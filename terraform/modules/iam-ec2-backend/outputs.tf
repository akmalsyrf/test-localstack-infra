output "policy_arn" {
  value = aws_iam_policy.ec2_backend.arn
}

output "role_arn" {
  value = aws_iam_role.session_manager.arn
}

output "role_name" {
  value = aws_iam_role.session_manager.name
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.this.name
}
