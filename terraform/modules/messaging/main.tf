# LocalStack-friendly messaging (standard SNS + SQS). FIFO SNS is Pro-only.
# No tags: LocalStack SNS tag/read waiters frequently hang after CreateTopic.
# Serialize creates: parallel SNS+SQS can deadlock moto locks (CreateTopic 500).

resource "aws_sns_topic" "unified" {
  name = "${var.prefix}-events-unified"
}

resource "aws_sqs_queue" "standard" {
  name                       = "${var.prefix}-standard"
  message_retention_seconds  = 18400
  visibility_timeout_seconds = 560

  depends_on = [aws_sns_topic.unified]
}

resource "aws_sqs_queue" "fifo" {
  name                        = "${var.prefix}-fifo.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 18400
  visibility_timeout_seconds  = 560

  depends_on = [aws_sqs_queue.standard]
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

resource "aws_sns_topic_subscription" "standard" {
  topic_arn            = aws_sns_topic.unified.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.standard.arn
  raw_message_delivery = true

  depends_on = [aws_sqs_queue_policy.standard]
}
