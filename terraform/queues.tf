resource "aws_sqs_queue" "dlq" {
  for_each = toset(local.consumers)

  name                        = local.dlq_names[each.key]
  fifo_queue                  = true
  content_based_deduplication = false
  sqs_managed_sse_enabled     = true
  visibility_timeout_seconds  = 30
  receive_wait_time_seconds   = 20
  message_retention_seconds   = local.dlq_retention_seconds[each.key]
}

resource "aws_sqs_queue" "consumer" {
  for_each = toset(local.consumers)

  name                        = local.queue_names[each.key]
  fifo_queue                  = true
  content_based_deduplication = false
  sqs_managed_sse_enabled     = true
  visibility_timeout_seconds  = 30
  receive_wait_time_seconds   = 20
  message_retention_seconds   = local.queue_retention_seconds[each.key]
}

resource "aws_sqs_queue_redrive_policy" "consumer" {
  for_each = toset(local.consumers)

  queue_url = aws_sqs_queue.consumer[each.key].id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = toset(local.consumers)

  queue_url = aws_sqs_queue.dlq[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.consumer[each.key].arn]
  })
}
