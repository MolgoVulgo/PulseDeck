from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import math
import re
import socket

import yaml


DEFAULT_CONFIG_PATH = Path("/etc/pulsedeck-agent/agent.yml")
_AGENT_ID_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62})$")
_PCI_SLOT_RE = re.compile(r"^(?:[0-9A-Fa-f]{4}:)?[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$")
_TEMP_LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class AgentConfig:
    agent_id: str
    name: str
    network_interface: str
    gpu_enabled: bool
    gpu_pci_slot: str | None
    gpu_temperature_labels: tuple[str, ...]
    sample_interval_s: float


def load_config(path: str | Path = DEFAULT_CONFIG_PATH) -> AgentConfig:
    config_path = Path(path)
    try:
        raw = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError(f"cannot read config {config_path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise ConfigError(f"invalid YAML in {config_path}: {exc}") from exc

    if raw is None:
        raw = {}
    root = _mapping(raw, "root")
    _only_keys(root, {"agent", "collectors", "runtime"}, "root")

    agent = _mapping(root.get("agent", {}), "agent")
    _only_keys(agent, {"id", "name"}, "agent")
    hostname = socket.gethostname().strip() or "host"
    agent_id_raw = str(agent.get("id", "auto")).strip()
    agent_id = _normalize_id(hostname) if agent_id_raw == "auto" else agent_id_raw.lower()
    if not _AGENT_ID_RE.fullmatch(agent_id):
        raise ConfigError("agent.id must match [a-z0-9][a-z0-9-]{0,62} or be 'auto'")
    name_raw = str(agent.get("name", "auto")).strip()
    name = hostname if name_raw == "auto" else name_raw
    if not name or len(name) > 128 or any(ord(ch) < 32 for ch in name):
        raise ConfigError("agent.name must be a non-empty printable string up to 128 characters")

    collectors = _mapping(root.get("collectors", {}), "collectors")
    _only_keys(collectors, {"cpu", "memory", "network", "gpu"}, "collectors")
    for mandatory in ("cpu", "memory"):
        section = _mapping(collectors.get(mandatory, {}), f"collectors.{mandatory}")
        _only_keys(section, set(), f"collectors.{mandatory}")

    network = _mapping(collectors.get("network", {}), "collectors.network")
    _only_keys(network, {"interface"}, "collectors.network")
    network_interface = str(network.get("interface", "auto")).strip()
    if not network_interface or len(network_interface) > 64 or any(ch.isspace() for ch in network_interface):
        raise ConfigError("collectors.network.interface must be 'auto' or a valid interface name")

    gpu = _mapping(collectors.get("gpu", {}), "collectors.gpu")
    _only_keys(gpu, {"enabled", "pci_slot", "temperature_labels"}, "collectors.gpu")
    gpu_enabled = _bool(gpu.get("enabled", False), "collectors.gpu.enabled")
    pci_raw = gpu.get("pci_slot")
    gpu_pci_slot = None if pci_raw in (None, "") else str(pci_raw).strip().lower()
    if gpu_pci_slot and not _PCI_SLOT_RE.fullmatch(gpu_pci_slot):
        raise ConfigError("collectors.gpu.pci_slot must use PCI BDF form dddd:bb:ss.f or bb:ss.f")
    labels_raw = gpu.get("temperature_labels", ["edge", "junction", "mem", "unknown"])
    if not isinstance(labels_raw, list) or not labels_raw:
        raise ConfigError("collectors.gpu.temperature_labels must be a non-empty YAML list")
    labels: list[str] = []
    for item in labels_raw:
        label = str(item).strip().lower()
        if not _TEMP_LABEL_RE.fullmatch(label):
            raise ConfigError("collectors.gpu.temperature_labels contains an invalid label")
        if label not in labels:
            labels.append(label)
    if "unknown" not in labels:
        labels.append("unknown")

    runtime = _mapping(root.get("runtime", {}), "runtime")
    _only_keys(runtime, {"sample_interval_s"}, "runtime")
    sample_interval_s = _float(runtime.get("sample_interval_s", 1.0), "runtime.sample_interval_s")
    if sample_interval_s < 0.25 or sample_interval_s > 60.0:
        raise ConfigError("runtime.sample_interval_s must be in [0.25, 60.0]")

    return AgentConfig(
        agent_id=agent_id,
        name=name,
        network_interface=network_interface,
        gpu_enabled=gpu_enabled,
        gpu_pci_slot=gpu_pci_slot,
        gpu_temperature_labels=tuple(labels),
        sample_interval_s=sample_interval_s,
    )


def _mapping(value: object, path: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ConfigError(f"{path} must be a YAML mapping")
    if not all(isinstance(key, str) for key in value):
        raise ConfigError(f"{path} keys must be strings")
    return value


def _only_keys(value: dict[str, object], allowed: set[str], path: str) -> None:
    unexpected = sorted(set(value) - allowed)
    if unexpected:
        raise ConfigError(f"{path} contains unsupported key(s): {', '.join(unexpected)}")


def _bool(value: object, path: str) -> bool:
    if isinstance(value, bool):
        return value
    raise ConfigError(f"{path} must be true or false")


def _float(value: object, path: str) -> float:
    if isinstance(value, bool):
        raise ConfigError(f"{path} must be a number")
    try:
        parsed = float(value)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{path} must be a number") from exc
    if not math.isfinite(parsed):
        raise ConfigError(f"{path} must be finite")
    return parsed


def _normalize_id(hostname: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", hostname.lower()).strip("-")
    value = value[:63].rstrip("-")
    return value or "host"
