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
