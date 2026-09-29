import threading

from pulsedeck_hub.mqtt.client import HubMQTTClient


def test_retained_snapshot_filters_by_service_and_returns_copies() -> None:
    client = HubMQTTClient.__new__(HubMQTTClient)
    client._retained_lock = threading.Lock()
    client._retained_publications = {
        "weather/current": {"topic": "pulsedeck/v1/weather/current", "payload": "{}", "published_at": 10, "qos": 1},
        "weather/hourly": {"topic": "pulsedeck/v1/weather/hourly", "payload": "{}", "published_at": 11, "qos": 1},
        "news/latest": {"topic": "pulsedeck/v1/news/latest", "payload": "{}", "published_at": 12, "qos": 1},
    }

    weather = client.retained_snapshot("weather")

    assert set(weather) == {"weather/current", "weather/hourly"}
    weather["weather/current"]["payload"] = "changed"
    assert client._retained_publications["weather/current"]["payload"] == "{}"

class _PublishInfo:
    rc = 0

    def wait_for_publish(self, timeout: float) -> None:
        return None

    def is_published(self) -> bool:
        return True


class _Publisher:
    def __init__(self) -> None:
        self.calls: list[tuple[str, object, int, bool]] = []

    def publish(self, topic: str, *, payload: object, qos: int, retain: bool) -> _PublishInfo:
        self.calls.append((topic, payload, qos, retain))
        return _PublishInfo()


def test_binary_retained_payload_is_not_copied_into_admin_snapshot() -> None:
    from types import SimpleNamespace

    client = HubMQTTClient.__new__(HubMQTTClient)
    client.config = SimpleNamespace(namespace="pulsedeck/v1")
    client.connected = threading.Event()
    client.connected.set()
    client.client = _Publisher()
    client._retained_lock = threading.Lock()
    client._retained_publications = {}

    assert client.publish_retained_binary("printer/cc2-main/thumbnail", b"\x89PNG", qos=1)
    snapshot = client.retained_snapshot("printer/cc2-main")
    entry = snapshot["printer/cc2-main/thumbnail"]
    assert entry["payload"] == "<binary:4 bytes>"
    assert entry["binary"] is True
    assert entry["size"] == 4

    assert client.clear_retained("printer/cc2-main/thumbnail")
    assert client.retained_snapshot("printer/cc2-main") == {}
