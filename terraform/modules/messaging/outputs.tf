output "sns_topic_arn" {
  value = aws_sns_topic.unified.arn
}

output "standard_queue_url" {
  value = aws_sqs_queue.standard.url
}

output "standard_queue_name" {
  value = aws_sqs_queue.standard.name
}

output "standard_queue_arn" {
  value = aws_sqs_queue.standard.arn
}

output "standard_dlq_url" {
  value = aws_sqs_queue.standard_dlq.url
}

output "standard_dlq_arn" {
  value = aws_sqs_queue.standard_dlq.arn
}

output "fifo_queue_url" {
  value = aws_sqs_queue.fifo.url
}

output "fifo_queue_arn" {
  value = aws_sqs_queue.fifo.arn
}
