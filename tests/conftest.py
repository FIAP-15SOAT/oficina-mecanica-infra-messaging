import json
import os
import time
import urllib.request
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import boto3
import pytest

REGION = "us-east-1"
TOPIC_NAME = "oficina-events.fifo"
SUBSCRIBED_TYPES: dict[str, list[str]] = json.loads(
    (Path(__file__).parents[1] / "terraform" / "subscribed-types.json").read_text()
)
MAPPED: list[tuple[str, str]] = [(t, c) for c, types in SUBSCRIBED_TYPES.items() for t in types]
UNKNOWN_TYPE = "routing.test.unknown"


@dataclass
class Received:
    consumer: str
    body: dict
    attributes: dict[str, str]


@pytest.fixture(scope="session", autouse=True)
def localstack_ready():
    # Without AWS_ENDPOINT_URL the suite targets AWS, where there is no init to wait for
    endpoint = os.environ.get("AWS_ENDPOINT_URL")
    if not endpoint:
        return
    deadline = time.monotonic() + 60
    status = {"completed": False, "scripts": []}
    while not status["completed"]:
        if time.monotonic() > deadline:
            pytest.fail(f"LocalStack init not completed after 60 s at {endpoint}")
        try:
            with urllib.request.urlopen(f"{endpoint}/_localstack/init/ready", timeout=5) as response:
                status = json.load(response)
        except OSError:
            time.sleep(1)
            continue
        if not status["completed"]:
            time.sleep(1)
    if not status["scripts"]:
        pytest.fail("LocalStack init completed without running any script: is init-topology.sh mounted in ready.d?")
    failed =[f"{s['name']}: {s['state']}" for s in status["scripts"] if s["state"] != "SUCCESSFUL"]
    if failed:
        pytest.fail("LocalStack init scripts failed: " + ", ".join(failed))


@pytest.fixture(scope="session")
def sns():
    # The endpoint comes from AWS_ENDPOINT_URL, read by botocore
    return boto3.client("sns", region_name=REGION)


@pytest.fixture(scope="session")
def sqs():
    return boto3.client("sqs", region_name=REGION)


@pytest.fixture(scope="session")
def topic_arn():
    account = boto3.client("sts", region_name=REGION).get_caller_identity()["Account"]
    return f"arn:aws:sns:{REGION}:{account}:{TOPIC_NAME}"


@pytest.fixture(scope="session")
def queue_urls(sqs):
    return {c: sqs.get_queue_url(QueueName=f"{c}.fifo")["QueueUrl"] for c in SUBSCRIBED_TYPES}


@pytest.fixture(scope="session")
def subscriptions(sns, topic_arn):
    result = {}
    for page in sns.get_paginator("list_subscriptions_by_topic").paginate(TopicArn=topic_arn):
        for subscription in page["Subscriptions"]:
            consumer = subscription["Endpoint"].rsplit(":", 1)[-1].removesuffix(".fifo")
            result[consumer] = sns.get_subscription_attributes(
                SubscriptionArn=subscription["SubscriptionArn"]
            )["Attributes"]
    return result


@dataclass
class Published:
    body: dict
    traceparent: str


@pytest.fixture(scope="session")
def published(sns, topic_arn):
    # One fresh messageId per message and per run, so reruns inside the 5-minute
    # deduplication window are not dropped and leftovers from other runs are ignored
    result = {}
    for message_type in [t for t, _ in MAPPED] + [UNKNOWN_TYPE]:
        message_id = str(uuid.uuid4())
        message = Published(
            body={
                "messageId": message_id,
                "type": message_type,
                "occurredAt": datetime.now(timezone.utc).isoformat(),
                "workOrderId": None,
                "payload": {},
            },
            traceparent=f"00-{uuid.uuid4().hex}-{uuid.uuid4().hex[:16]}-01",
        )
        result[message_type] = message
        # The second, identical copy proves FIFO deduplication: each queue must get a single one
        for _ in range(2):
            sns.publish(
                TopicArn=topic_arn,
                Message=json.dumps(message.body),
                MessageGroupId=message_id,
                MessageDeduplicationId=message_id,
                MessageAttributes={
                    "type": {"DataType": "String", "StringValue": message_type},
                    "traceparent": {"DataType": "String", "StringValue": message.traceparent},
                },
            )
    return result


@pytest.fixture(scope="session")
def deliveries(sqs, queue_urls, published):
    sent = {m.body["messageId"] for m in published.values()}
    received = {t: [] for t in published}

    def poll(done, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and not done():
            for consumer, url in queue_urls.items():
                messages = sqs.receive_message(
                    QueueUrl=url,
                    MaxNumberOfMessages=10,
                    WaitTimeSeconds=1,
                    MessageAttributeNames=["All"],
                ).get("Messages", [])
                for message in messages:
                    body = json.loads(message["Body"])
                    if body.get("messageId") not in sent:
                        continue
                    attributes = {k: v["StringValue"] for k, v in message.get("MessageAttributes", {}).items()}
                    received[body["type"]].append(Received(consumer, body, attributes))
                    sqs.delete_message(QueueUrl=url, ReceiptHandle=message["ReceiptHandle"])

    poll(lambda: all(received[t] for t, _ in MAPPED), 30)
    poll(lambda: False, 3)  # extra copies or misrouted messages arriving late
    return received
