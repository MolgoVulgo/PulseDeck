from __future__ import annotations

from dataclasses import dataclass
import socket
import time
from typing import Any

from ..collectors.metric import MetricReading


@dataclass(frozen=True)
class AgentIdentity:
    agent_id: str
    name: str

    def as_dict(self) -> dict[str, str]:
        return {"id": self.agent_id, "name": self.name, "host": socket.gethostname()}


def metrics_dict(values: dict[str, MetricReading | str]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in values.items():
        result[key] = value.as_dict() if isinstance(value, MetricReading) else value
    return result


def build_snapshot(
    *,
    identity: AgentIdentity,
    cpu: dict[str, MetricReading],
    memory: dict[str, MetricReading],
    network: dict[str, MetricReading | str],
    gpu: dict[str, MetricReading] | None,
) -> dict[str, Any]:
    capabilities = ["cpu", "memory", "network"]
    if gpu is not None:
        capabilities.append("gpu")

    required_ok = (
        cpu["pct"].valid
        and memory["used_b"].valid
        and memory["total_b"].valid
        and memory["pct"].valid
        and isinstance(network.get("rx_bytes"), MetricReading)
        and network["rx_bytes"].valid  # type: ignore[union-attr]
        and isinstance(network.get("tx_bytes"), MetricReading)
        and network["tx_bytes"].valid  # type: ignore[union-attr]
    )

    snapshot: dict[str, Any] = {
        "schema": 1,
        "ts": int(time.time()),
        "agent": identity.as_dict(),
        "capabilities": capabilities,
        "cpu": metrics_dict(cpu),
        "memory": metrics_dict(memory),
        "network": metrics_dict(network),
        "state": {"ok": bool(required_ok)},
    }
    if gpu is not None:
        snapshot["gpu"] = metrics_dict(gpu)
    return snapshot
