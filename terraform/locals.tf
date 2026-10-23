locals {
  subscribed_types = jsondecode(file("${path.module}/subscribed-types.json"))
  consumers        = keys(local.subscribed_types)

  topic_name  = "oficina-events.fifo"
  queue_names = { for c in local.consumers : c => "${c}.fifo" }
  dlq_names   = { for c in local.consumers : c => "${c}-dlq.fifo" }

  # notification holds e-mail data, so its queue and DLQ keep messages for 1 day;
  # the other queues keep 4 days and their DLQs 14 days (SQS maximum) for manual redrive
  queue_retention_seconds = { for c in local.consumers : c => c == "notification" ? 86400 : 345600 }
  dlq_retention_seconds   = { for c in local.consumers : c => c == "notification" ? 86400 : 1209600 }
}
