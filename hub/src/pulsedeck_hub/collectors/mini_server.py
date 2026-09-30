"""PulseDeck Agent collector for the first monitored mini-server."""

from __future__ import annotations

import json
import logging
import threading
import time
from typing import Any, Callable, TYPE_CHECKING
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from ..config import MiniServerConfig
from ..mqtt.payloads import encode_payload, source_availability_payload


if TYPE_CHECKING:
    from ..mqtt.client import HubMQTTClient


LOG = logging.getLogger(__name__)
AGENT_PROTOCOL = "pulsedeck-agent-http"
AGENT_WIRE_SCHEMA = 1
DASHBOARD_SCHEMA = 1
AVAILABILITY_SUFFIX = "server/mini/availability"
DASHBOARD_SUFFIX = "server/mini/dashboard"


FetchJson = Callable[[str, float], dict[str, object]]


def _fetch_json(url: str, timeout: float) -> dict[str, object]:
    request = Request(url, headers={"Accept": "application/json", "User-Agent": "PulseDeck-Hub/1"})
    with urlopen(request, timeout=timeout) as response:
        if response.status != 200:
            raise RuntimeError(f"Agent HTTP returned {response.status}")
        body = response.read(1_000_001)
        if len(body) > 1_000_000:
            raise RuntimeError("Agent payload exceeds 1 MB")
    payload = json.loads(body.decode("utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError("Agent payload root must be an object")
    return payload


def _metric_value(section: object, key: str) -> object | None:
    if not isinstance(section, dict):
        return None
    metric = section.get(key)
    if not isinstance(metric, dict) or metric.get("valid") is not True:
        return None
    return metric.get("value_raw")


def normalize_agent_snapshot(payload: dict[str, object], *, target_host: str, max_age: int) -> dict[str, object]:
    if payload.get("schema") != AGENT_WIRE_SCHEMA or payload.get("protocol") != AGENT_PROTOCOL:
        raise ValueError("unsupported Agent wire contract")
    snapshot = payload.get("snapshot")
    if not isinstance(snapshot, dict) or snapshot.get("schema") != 1:
        raise ValueError("invalid Agent snapshot")
    snapshot_ts = snapshot.get("ts")
    if isinstance(snapshot_ts, bool) or not isinstance(snapshot_ts, int):
        raise ValueError("Agent snapshot ts must be an integer")
    now = int(time.time())
    if snapshot_ts > now + 30 or now - snapshot_ts > max_age:
        raise ValueError("Agent snapshot is stale")
    state = snapshot.get("state")
    if not isinstance(state, dict) or state.get("ok") is not True:
        raise ValueError("Agent mandatory metrics are not healthy")
    agent = snapshot.get("agent")
    if not isinstance(agent, dict):
        raise ValueError("Agent identity missing")
    agent_id = agent.get("id")
    agent_name = agent.get("name")
    if not isinstance(agent_id, str) or not agent_id:
        raise ValueError("Agent id missing")
    if not isinstance(agent_name, str) or not agent_name:
        raise ValueError("Agent name missing")

    cpu = snapshot.get("cpu")
    memory = snapshot.get("memory")
    network = snapshot.get("network")
    if not isinstance(network, dict):
        raise ValueError("Agent network section missing")
    interface = network.get("interface")
    if not isinstance(interface, str) or not interface:
        raise ValueError("Agent network interface missing")

    return {
        "schema": DASHBOARD_SCHEMA,
        "ts": snapshot_ts,
        "source": "pulsedeck-agent",
        "agent": {"id": agent_id, "name": agent_name},
        "target": {"host": target_host},
        "data": {
            "cpu": {
                "usage_pct": _metric_value(cpu, "pct"),
                "temperature_c": _metric_value(cpu, "temp_c"),
                "power_w": _metric_value(cpu, "power_w"),
            },
            "memory": {
                "used_b": _metric_value(memory, "used_b"),
                "total_b": _metric_value(memory, "total_b"),
                "usage_pct": _metric_value(memory, "pct"),
            },
            "network": {
                "interface": interface,
                "rx_bps": _metric_value(network, "rx_bps"),
                "tx_bps": _metric_value(network, "tx_bps"),
                "rx_bytes": _metric_value(network, "rx_bytes"),
                "tx_bytes": _metric_value(network, "tx_bytes"),
            },
        },
    }


class MiniServerCollector:
    def __init__(
        self,
        config: MiniServerConfig,
        mqtt_client: HubMQTTClient,
        *,
        fetch_json: FetchJson = _fetch_json,
    ) -> None:
        self.config = config
        self.mqtt_client = mqtt_client
        self.fetch_json = fetch_json
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._state = "starting"
        self._last_success: int | None = None
        self._last_error: str | None = None
        self._failures = 0
        self._announced_state: str | None = None

    @property
    def snapshot_url(self) -> str:
        return f"http://{self.config.host}:{self.config.port}/v1/snapshot"

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="pulsedeck-mini-server", daemon=True)
        self._thread.start()
        LOG.info("Mini-server Agent polling enabled for %s", self.snapshot_url)

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        self._thread = None
        if thread is not None:
            thread.join(timeout=max(2.0, float(self.config.request_timeout) + 1.0))

    def poll_once(self) -> bool:
        try:
            wire = self.fetch_json(self.snapshot_url, float(self.config.request_timeout))
            dashboard = normalize_agent_snapshot(
                wire,
                target_host=self.config.host,
                max_age=self.config.max_snapshot_age,
            )
            now = int(time.time())
            with self._lock:
                self._state = "online"
                self._last_success = now
                self._last_error = None
                self._failures = 0
                announce_online = self._announced_state != "online"

            if not self.mqtt_client.publish_retained(DASHBOARD_SUFFIX, encode_payload(dashboard), qos=1):
                LOG.warning("Mini-server dashboard could not be published to MQTT")
            if announce_online and self.mqtt_client.publish_retained(
                AVAILABILITY_SUFFIX,
                source_availability_payload("online", source="pulsedeck-agent", last_success=now),
                qos=1,
            ):
                with self._lock:
                    self._announced_state = "online"
            return True
        except (HTTPError, URLError, TimeoutError, OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
            self._record_failure(str(exc))
            return False

    def status(self) -> dict[str, object]:
        with self._lock:
            return {
                "enabled": self.config.enabled,
                "host": self.config.host,
                "port": self.config.port,
                "profile": "mini-server",
                "transport": "http",
                "state": self._state,
                "last_success": self._last_success,
                "last_error": self._last_error,
                "consecutive_failures": self._failures,
            }

    def _run(self) -> None:
        while not self._stop.is_set():
            started = time.monotonic()
            self.poll_once()
            delay = max(0.0, float(self.config.poll_interval) - (time.monotonic() - started))
            self._stop.wait(delay)

    def _record_failure(self, reason: str) -> None:
        announce_offline = False
        last_success: int | None
        with self._lock:
            self._failures += 1
            self._last_error = reason[:240]
            last_success = self._last_success
            if self._failures >= self.config.offline_after_failures:
                if self._state != "offline":
                    LOG.warning("Mini-server Agent unavailable at %s: %s", self.snapshot_url, reason)
                self._state = "offline"
                announce_offline = self._announced_state != "offline"
        if announce_offline and self.mqtt_client.publish_retained(
            AVAILABILITY_SUFFIX,
            source_availability_payload(
                "offline",
                source="pulsedeck-agent",
                last_success=last_success,
                reason="agent_unreachable_or_invalid",
            ),
            qos=1,
        ):
            with self._lock:
                self._announced_state = "offline"
