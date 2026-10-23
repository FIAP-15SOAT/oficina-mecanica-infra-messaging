output "topic_arn" {
  description = "ARN of the oficina-events.fifo topic"
  value       = aws_sns_topic.events.arn
}

output "topic_name" {
  description = "Name of the oficina-events.fifo topic"
  value       = aws_sns_topic.events.name
}

output "queue_urls" {
  description = "Consumer queue URLs by consumer"
  value       = { for c, q in aws_sqs_queue.consumer : c => q.url }
}

output "queue_arns" {
  description = "Consumer queue ARNs by consumer"
  value       = { for c, q in aws_sqs_queue.consumer : c => q.arn }
}

output "dlq_urls" {
  description = "Dead-letter queue URLs by consumer"
  value       = { for c, q in aws_sqs_queue.dlq : c => q.url }
}

output "dlq_arns" {
  description = "Dead-letter queue ARNs by consumer"
  value       = { for c, q in aws_sqs_queue.dlq : c => q.arn }
}
