import json
import time
from pulsedeck_hub.collectors.mini_server import MiniServerCollector, normalize_agent_snapshot
from pulsedeck_hub.config import MiniServerConfig


def _metric(value, unit="percent", valid=True):
    return {"value_raw": value if valid else None, "unit": unit, "valid": valid}


def _wire(ts=None):
    return {
        "schema": 1,
        "protocol": "pulsedeck-agent-http",
        "snapshot": {
            "schema": 1,
            "ts": int(time.time()) if ts is None else ts,
            "agent": {"id": "mini-server", "name": "Mini Server"},
            "state": {"ok": True},
            "cpu": {"pct": _metric(12.5), "temp_c": _metric(44.0, "celsius"), "power_w": _metric(None, "watt", False)},
            "memory": {"used_b": _metric(100, "bytes"), "total_b": _metric(200, "bytes"), "pct": _metric(50.0)},
            "network": {
                "interface": "eth0",
                "rx_bps": _metric(1000, "bytes_per_second"),
                "tx_bps": _metric(2000, "bytes_per_second"),
                "rx_bytes": _metric(3000, "bytes"),
                "tx_bytes": _metric(4000, "bytes"),
            },
        },
    }


class FakeMQTT:
    def __init__(self):
        self.calls = []

    def publish_retained(self, suffix, payload, *, qos=1):
        self.calls.append((suffix, json.loads(payload), qos))
        return True


def test_normalize_agent_snapshot_is_display_oriented_and_preserves_unavailable_as_null() -> None:
    dashboard = normalize_agent_snapshot(_wire(), target_host="10.0.0.42", max_age=10)
    assert dashboard["target"]["host"] == "10.0.0.42"
    assert dashboard["data"]["cpu"]["usage_pct"] == 12.5
    assert dashboard["data"]["cpu"]["power_w"] is None
    assert dashboard["data"]["network"]["interface"] == "eth0"


def test_collector_uses_configured_host_and_port_and_publishes_retained() -> None:
    mqtt = FakeMQTT()
    seen = {}

    def fetch(url, timeout):
        seen.update(url=url, timeout=timeout)
        return _wire()

    cfg = MiniServerConfig(enabled=True, host="10.0.0.42", port=9999, request_timeout=4)
    collector = MiniServerCollector(cfg, mqtt, fetch_json=fetch)
    assert collector.snapshot_url == "http://10.0.0.42:9999/v1/snapshot"
    assert collector.poll_once() is True
    assert seen == {"url": collector.snapshot_url, "timeout": 4.0}
    assert [call[0] for call in mqtt.calls] == ["server/mini/dashboard", "server/mini/availability"]
    assert all(call[2] == 1 for call in mqtt.calls)
    assert collector.status()["state"] == "online"


def test_collector_transitions_offline_only_after_configured_failure_threshold() -> None:
    mqtt = FakeMQTT()

    def fail(url, timeout):
        raise RuntimeError("unreachable")

    cfg = MiniServerConfig(enabled=True, host="10.0.0.42", offline_after_failures=2)
    collector = MiniServerCollector(cfg, mqtt, fetch_json=fail)
    assert collector.poll_once() is False
    assert collector.status()["state"] == "starting"
    assert collector.poll_once() is False
    assert collector.status()["state"] == "offline"
    assert mqtt.calls[-1][0] == "server/mini/availability"
    assert mqtt.calls[-1][1]["state"] == "offline"


def test_stale_agent_snapshot_is_rejected() -> None:
    old = int(time.time()) - 60
    try:
        normalize_agent_snapshot(_wire(old), target_host="10.0.0.42", max_age=10)
    except ValueError as exc:
        assert "stale" in str(exc)
    else:
        raise AssertionError("stale snapshot accepted")
