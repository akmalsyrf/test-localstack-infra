# EC2 backend IAM role + policy
# LocalStack free: use inline custom policies (AWS managed SSM policies may be missing)

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "ec2_backend" {
  name        = var.policy_name
  description = "Policy for EC2 backend access to Secrets Manager, S3, CloudWatch Logs"
  policy      = var.policy_json
  tags        = var.tags
}

resource "aws_iam_role" "session_manager" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
  description        = "EC2 Session Manager + backend access (LocalStack)"
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ec2_backend" {
  role       = aws_iam_role.session_manager.name
  policy_arn = aws_iam_policy.ec2_backend.arn
}

# Local SSM-like permissions (instead of AmazonSSMManagedInstanceCore)
resource "aws_iam_role_policy" "ssm_core" {
  name = "${var.role_name}-ssm-core"
  role = aws_iam_role.session_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "ec2messages:AcknowledgeMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = var.role_name
  role = aws_iam_role.session_manager.name
  tags = var.tags
}
