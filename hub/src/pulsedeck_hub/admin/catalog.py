"""Service catalog metadata for the PulseDeck Admin navigation."""

from __future__ import annotations

from typing import Any


def build_service_catalog(
    weather_state: dict[str, Any],
    weather_enabled: bool,
    news_state: dict[str, Any],
    news_enabled: bool,
    news_provider: str = "newsapi",
    printer_state: dict[str, Any] | None = None,
    printer_enabled: bool = False,
    machines_state: dict[str, Any] | None = None,
    machines_enabled: bool = False,
) -> list[dict[str, Any]]:
    """Return stable Admin metadata for implemented collectors."""

    machines = machines_state or {}
    configured = int(machines.get("configured_devices", 0) or 0)
    enabled = int(machines.get("enabled_devices", configured) or 0)
    online = int(machines.get("online_devices", 0) or 0)
    return [
        {
            "id": "weather",
            "label": "Weather",
            "available": True,
            "state": weather_state.get("state", "disabled"),
            "enabled": weather_enabled,
            "provider": "OpenWeather One Call 4.0",
            "transport": "HTTPS",
            "auth": "API key",
            "view": "weather",
        },
        {
            "id": "news",
            "label": "News",
            "available": True,
            "state": news_state.get("state", "disabled"),
            "enabled": news_enabled,
            "provider": "GNews" if news_provider == "gnews" else "NewsAPI",
            "transport": "HTTPS",
            "auth": "X-Api-Key",
            "view": "news",
        },
        {
            "id": "machines",
            "label": "Machines / PC & serveurs",
            "available": True,
            "state": machines.get("state", "disabled"),
            "enabled": machines_enabled,
            "provider": f"PulseDeck Agent · {online}/{enabled} online" if enabled else "PulseDeck Agent",
            "transport": "HTTP LAN",
            "auth": "none (trusted LAN V1)",
            "view": "machines",
        },
        {
            "id": "printer",
            "label": "Printer",
            "available": True,
            "state": (printer_state or {}).get("state", "disabled"),
            "enabled": printer_enabled,
            "provider": "ELEGOO CC2",
            "transport": "MQTT LAN",
            "auth": "Access code",
            "view": "printer",
        },
    ]
