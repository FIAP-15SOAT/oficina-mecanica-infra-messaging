resource "aws_sns_topic" "events" {
  name                        = local.topic_name
  fifo_topic                  = true
  content_based_deduplication = false # publishers set MessageDeduplicationId = messageId
}
