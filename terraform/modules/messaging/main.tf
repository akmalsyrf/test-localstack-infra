# Mirrors backend/assets/events — LocalStack free: standard SNS (FIFO SNS often Pro-only)

resource "aws_sns_topic" "unified" {
  name = "${var.prefix}-events-unified"
  tags = var.tags
}

resource "aws_sqs_queue" "standard" {
  name                       = "${var.prefix}-standard"
  message_retention_seconds  = 18400
  visibility_timeout_seconds = 560
  tags                       = var.tags
}

resource "aws_sqs_queue" "fifo" {
  name                        = "${var.prefix}-fifo.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 18400
  visibility_timeout_seconds  = 560
  tags                        = var.tags
}

# LocalStack free: standard SNS only (FIFO SNS is Pro). FIFO queue kept standalone.
resource "aws_sns_topic_subscription" "standard" {
  topic_arn            = aws_sns_topic.unified.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.standard.arn
  raw_message_delivery = true
}

resource "aws_sqs_queue_policy" "standard" {
  queue_url = aws_sqs_queue.standard.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSNSPublish"
      Effect    = "Allow"
      Principal = "*"
      Action    = "SQS:SendMessage"
      Resource  = aws_sqs_queue.standard.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.unified.arn }
      }
    }]
  })
}
