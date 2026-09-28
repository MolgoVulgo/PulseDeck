import logging

from pulsedeck_hub.logging_setup import (
    classify_log_service,
    clear_log_buffer,
    configure_logging,
    recent_logs,
)


def test_log_service_classification() -> None:
    assert classify_log_service("pulsedeck_hub.main") == "hub"
    assert classify_log_service("pulsedeck_hub.mqtt.client") == "mqtt"
    assert classify_log_service("pulsedeck_hub.collectors.weather") == "weather"
    assert classify_log_service("pulsedeck_hub.collectors.news") == "news"
    assert classify_log_service("pulsedeck_hub.admin.routes") == "admin"
    assert classify_log_service("uvicorn.error") == "admin"


def test_recent_logs_filter_and_limit() -> None:
    clear_log_buffer()
    configure_logging()
    logging.getLogger("pulsedeck_hub.collectors.weather").warning("weather test entry")
    logging.getLogger("pulsedeck_hub.collectors.news").error("news test entry")

    all_entries = recent_logs("all", limit=20)
    assert [entry["message"] for entry in all_entries[-2:]] == ["weather test entry", "news test entry"]
    assert recent_logs("weather", limit=20)[-1]["service"] == "weather"
    assert recent_logs("news", limit=1)[-1]["message"] == "news test entry"
