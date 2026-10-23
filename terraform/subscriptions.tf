data "aws_iam_policy_document" "queue_from_topic" {
  for_each = toset(local.consumers)

  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.consumer[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "consumer" {
  for_each = toset(local.consumers)

  queue_url = aws_sqs_queue.consumer[each.key].id
  policy    = data.aws_iam_policy_document.queue_from_topic[each.key].json
}

resource "aws_sns_topic_subscription" "consumer" {
  for_each = toset(local.consumers)

  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.consumer[each.key].arn
  raw_message_delivery = true
  filter_policy_scope  = "MessageAttributes"
  filter_policy        = jsonencode({ type = local.subscribed_types[each.key] })

  # The queue must accept SNS deliveries before the subscription starts sending
  depends_on = [aws_sqs_queue_policy.consumer]
}
