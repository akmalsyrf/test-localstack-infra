output "sns_topic_arn" {
  value = aws_sns_topic.unified.arn
}

output "standard_queue_url" {
  value = aws_sqs_queue.standard.url
}

output "fifo_queue_url" {
  value = aws_sqs_queue.fifo.url
}
