import json

import pytest

from conftest import MAPPED, SUBSCRIBED_TYPES, UNKNOWN_TYPE


@pytest.mark.parametrize("consumer", sorted(SUBSCRIBED_TYPES))
def test_subscription_filters_exactly_mapped_types(subscriptions, consumer):
    attributes = subscriptions[consumer]
    assert attributes["RawMessageDelivery"] == "true"
    assert sorted(json.loads(attributes["FilterPolicy"])["type"]) == sorted(SUBSCRIBED_TYPES[consumer])


@pytest.mark.parametrize("message_type,consumer", MAPPED)
def test_type_reaches_only_its_consumer_queue(published, deliveries, message_type, consumer):
    received = deliveries[message_type]
    assert [r.consumer for r in received] == [consumer]
    assert received[0].body == published[message_type].body
    assert received[0].attributes == {
        "type": message_type,
        "traceparent": published[message_type].traceparent,
    }


def test_unknown_type_reaches_no_queue(deliveries):
    assert deliveries[UNKNOWN_TYPE] == []
