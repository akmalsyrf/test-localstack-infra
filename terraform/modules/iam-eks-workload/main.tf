# IAM role for EKS/Kind workloads that talk to SQS + SNS.
# Forward-compatible with IRSA: when enable_irsa_oidc=true and oidc_provider_arn
# is set, trust uses AssumeRoleWithWebIdentity. On LocalStack Community (no real
# EKS OIDC), leave enable_irsa_oidc=false — role+policy still exist for IAM shape,
# but pods use the LOCAL-ONLY kubernetes_secret "localstack-creds" bypass instead of IRSA.

data "aws_iam_policy_document" "irsa_trust" {
  count = var.enable_irsa_oidc && var.oidc_provider_arn != "" ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }
  }
}

# LOCAL-ONLY placeholder trust so the role can be created without a real OIDC issuer.
# Delete this path by setting enable_irsa_oidc=true + real oidc_provider_arn on EKS.
data "aws_iam_policy_document" "local_placeholder_trust" {
  count = !(var.enable_irsa_oidc && var.oidc_provider_arn != "") ? 1 : 0

  statement {
    sid     = "LocalStackPlaceholderNoOpTrust"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::000000000000:root"]
    }
  }
}

resource "aws_iam_role" "eks_workload" {
  name = var.role_name
  assume_role_policy = (
    var.enable_irsa_oidc && var.oidc_provider_arn != ""
    ? data.aws_iam_policy_document.irsa_trust[0].json
    : data.aws_iam_policy_document.local_placeholder_trust[0].json
  )
  tags = var.tags
}

resource "aws_iam_role_policy" "messaging" {
  name = "${var.role_name}-messaging"
  role = aws_iam_role.eks_workload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSQS"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = compact([var.sqs_standard_queue_arn, var.sqs_fifo_queue_arn])
      },
      {
        Sid      = "AllowSNSPublish"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [var.sns_topic_arn]
      }
    ]
  })
}

output "role_arn" {
  value = aws_iam_role.eks_workload.arn
}

output "role_name" {
  value = aws_iam_role.eks_workload.name
}
