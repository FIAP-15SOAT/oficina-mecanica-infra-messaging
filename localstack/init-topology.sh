#!/bin/bash
# Messaging topology of oficina-mecanica-infra-messaging for LocalStack.
# Source of truth: terraform/subscribed-types.json. Change this script and the
# map in the same PR; the Routing Tests job compares each filter policy below
# against the map. Services copy this file to app/localstack/init-topology.sh.
set -euo pipefail

REGION=us-east-1

topic_arn=$(awslocal sns create-topic --region "$REGION" --name oficina-events.fifo \
  --attributes FifoTopic=true,ContentBasedDeduplication=false \
  --query TopicArn --output text)

# create_consumer <consumer> <queue retention s> <dlq retention s> <filter policy>
create_consumer() {
  local consumer=$1 retention=$2 dlq_retention=$3 filter_policy=$4
  local common="FifoQueue=true,ContentBasedDeduplication=false,SqsManagedSseEnabled=true,VisibilityTimeout=30,ReceiveMessageWaitTimeSeconds=20"

  local dlq_url dlq_arn queue_url queue_arn subscription_arn
  dlq_url=$(awslocal sqs create-queue --region "$REGION" --queue-name "$consumer-dlq.fifo" \
    --attributes "$common,MessageRetentionPeriod=$dlq_retention" --query QueueUrl --output text)
  dlq_arn=$(awslocal sqs get-queue-attributes --region "$REGION" --queue-url "$dlq_url" \
    --attribute-names QueueArn --query Attributes.QueueArn --output text)

  queue_url=$(awslocal sqs create-queue --region "$REGION" --queue-name "$consumer.fifo" \
    --attributes "$common,MessageRetentionPeriod=$retention" --query QueueUrl --output text)
  queue_arn=$(awslocal sqs get-queue-attributes --region "$REGION" --queue-url "$queue_url" \
    --attribute-names QueueArn --query Attributes.QueueArn --output text)

  awslocal sqs set-queue-attributes --region "$REGION" --queue-url "$queue_url" --attributes \
    "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"$dlq_arn\\\",\\\"maxReceiveCount\\\":5}\"}"
  awslocal sqs set-queue-attributes --region "$REGION" --queue-url "$dlq_url" --attributes \
    "{\"RedriveAllowPolicy\":\"{\\\"redrivePermission\\\":\\\"byQueue\\\",\\\"sourceQueueArns\\\":[\\\"$queue_arn\\\"]}\"}"

  subscription_arn=$(awslocal sns subscribe --region "$REGION" --topic-arn "$topic_arn" \
    --protocol sqs --notification-endpoint "$queue_arn" \
    --attributes RawMessageDelivery=true --query SubscriptionArn --output text)
  awslocal sns set-subscription-attributes --region "$REGION" --subscription-arn "$subscription_arn" \
    --attribute-name FilterPolicy --attribute-value "$filter_policy"
}

create_consumer work-order 345600 1209600 '{"type":["billing.quote.sent","billing.quote.rejected","billing.quote.approved","billing.quote.approval_reverted","billing.payment.requested","billing.payment.approved","billing.payment.failed","inventory.stock.reserved","inventory.stock.reservation_failed"]}'
create_consumer billing 345600 1209600 '{"type":["billing.quote.revert_approval","billing.payment.cancel"]}'
create_consumer inventory 345600 1209600 '{"type":["inventory.stock.reserve","inventory.stock.consume"]}'
create_consumer notification 86400 86400 '{"type":["notification.email.send"]}'

echo "oficina-events.fifo topology ready"
