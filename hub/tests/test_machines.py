import json
import time

from pulsedeck_hub.collectors.machines import MachineCollector, MachinesCollector, normalize_agent_snapshot
from pulsedeck_hub.config import MachineDeviceConfig, MachinesConfig


def _metric(value, unit="percent", valid=True):
    return {"value_raw": value if valid else None, "unit": unit, "valid": valid}


def _wire(ts=None, *, gpu=False):
    snapshot = {
        "schema": 1,
        "ts": int(time.time()) if ts is None else ts,
        "agent": {"id": "host-agent", "name": "Host Agent"},
        "capabilities": ["cpu", "memory", "network"] + (["gpu"] if gpu else []),
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
    }
    if gpu:
        snapshot["gpu"] = {
            "pct": _metric(75.0),
            "temp_c": _metric(65.0, "celsius"),
            "power_w": _metric(120.0, "watt"),
            "core_clock_mhz": _metric(2200, "mhz"),
            "mem_clock_mhz": _metric(1000, "mhz"),
            "vram_used_b": _metric(4_000_000_000, "bytes"),
            "vram_total_b": _metric(8_000_000_000, "bytes"),
            "fan_rpm": _metric(1500, "rpm"),
            "fan_pct": _metric(40.0),
        }
    return {"schema": 1, "protocol": "pulsedeck-agent-http", "snapshot": snapshot}


class FakeMQTT:
    def __init__(self):
        self.calls = []

    def publish_retained(self, suffix, payload, *, qos=1):
        self.calls.append((suffix, json.loads(payload), qos))
        return True


def _device(machine_id="mini-server"):
    return MachineDeviceConfig(id=machine_id, name="Mini serveur", host="10.0.0.42", port=9999)


def test_normalize_agent_snapshot_is_machine_scoped_and_preserves_gpu() -> None:
    dashboard = normalize_agent_snapshot(_wire(gpu=True), target=_device("gaming-pc"), max_age=10)
    assert dashboard["machine"] == {"id": "gaming-pc", "name": "Mini serveur", "host": "10.0.0.42"}
    assert dashboard["agent"]["id"] == "host-agent"
    assert dashboard["data"]["cpu"]["power_w"] is None
    assert dashboard["data"]["network"]["interface"] == "eth0"
    assert dashboard["data"]["gpu"]["usage_pct"] == 75.0
    assert dashboard["data"]["gpu"]["vram_total_b"] == 8_000_000_000


def test_machine_collector_uses_dynamic_topic_prefix() -> None:
    mqtt = FakeMQTT()
    seen = {}

    def fetch(url, timeout):
        seen.update(url=url, timeout=timeout)
        return _wire()

    settings = MachinesConfig(enabled=True, devices=(_device(),), request_timeout=4)
    collector = MachineCollector(_device(), settings, mqtt, fetch_json=fetch)
    assert collector.snapshot_url == "http://10.0.0.42:9999/v1/snapshot"
    assert collector.poll_once() is True
    assert seen == {"url": collector.snapshot_url, "timeout": 4.0}
    assert [call[0] for call in mqtt.calls] == ["machine/mini-server/dashboard", "machine/mini-server/availability"]
    assert all(call[2] == 1 for call in mqtt.calls)
    assert collector.status()["state"] == "online"


def test_machine_collector_transitions_offline_after_threshold() -> None:
    mqtt = FakeMQTT()

    def fail(url, timeout):
        raise RuntimeError("unreachable")

    settings = MachinesConfig(enabled=True, devices=(_device(),), offline_after_failures=2)
    collector = MachineCollector(_device(), settings, mqtt, fetch_json=fail)
    assert collector.poll_once() is False
    assert collector.status()["state"] == "starting"
    assert collector.poll_once() is False
    assert collector.status()["state"] == "offline"
    assert mqtt.calls[-1][0] == "machine/mini-server/availability"
    assert mqtt.calls[-1][1]["state"] == "offline"


def test_stale_agent_snapshot_is_rejected() -> None:
    old = int(time.time()) - 60
    try:
        normalize_agent_snapshot(_wire(old), target=_device(), max_age=10)
    except ValueError as exc:
        assert "stale" in str(exc)
    else:
        raise AssertionError("stale snapshot accepted")


def test_multi_collector_keeps_disabled_devices_in_runtime_snapshot() -> None:
    enabled = _device("server-a")
    disabled = MachineDeviceConfig(id="server-b", name="Server B", host="server-b.local", enabled=False)
    cfg = MachinesConfig(enabled=True, devices=(enabled, disabled))
    collector = MachinesCollector(cfg, FakeMQTT())
    status = collector.status()
    assert status["configured_devices"] == 2
    assert status["enabled_devices"] == 1
    by_id = {item["id"]: item for item in status["devices"]}
    assert by_id["server-b"]["state"] == "disabled"
