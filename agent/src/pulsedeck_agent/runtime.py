from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import threading
import time

from .collectors import AmdGpuCollector, NetworkCollector, collect_cpu, collect_memory
from .config import AgentConfig
from .http_server import AgentHTTPServer
from .models import AgentIdentity, build_snapshot


DEFAULT_STATE_DIR = Path("/var/lib/pulsedeck-agent")


class AgentRuntime:
    def __init__(self, config: AgentConfig) -> None:
        self.config = config
        self.identity = AgentIdentity(config.agent_id, config.name)
        self.network = NetworkCollector(config.network_interface)
        self._latest_lock = threading.Lock()
        self._latest_snapshot: dict[str, object] | None = None
        self.http_server: AgentHTTPServer | None = None
        self.gpu = (
            AmdGpuCollector(
                pci_slot=config.gpu_pci_slot,
                temperature_labels=config.gpu_temperature_labels,
            )
            if config.gpu_enabled
            else None
        )

    def collect(self) -> dict[str, object]:
        gpu = self.gpu.collect() if self.gpu is not None else None
        snapshot = build_snapshot(
            identity=self.identity,
            cpu=collect_cpu(),
            memory=collect_memory(),
            network=self.network.collect(),
            gpu=gpu,
        )
        with self._latest_lock:
            self._latest_snapshot = snapshot
        return snapshot

    def latest_snapshot(self) -> dict[str, object] | None:
        with self._latest_lock:
            return None if self._latest_snapshot is None else deepcopy(self._latest_snapshot)

    def warm_collect(self, delay_s: float = 0.2) -> dict[str, object]:
        self.collect()
        time.sleep(max(0.05, delay_s))
        return self.collect()

    def run_forever(self, state_dir: str | Path = DEFAULT_STATE_DIR) -> None:
        directory = Path(state_dir)
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / "snapshot.json"

        if self.config.transport_enabled:
            self.http_server = AgentHTTPServer(
                self.config.transport_listen,
                self.config.transport_port,
                self.latest_snapshot,
            )
            self.http_server.start()

        next_run = time.monotonic()
        try:
            while True:
                snapshot = self.collect()
                _write_json_atomic(target, snapshot)
                next_run += self.config.sample_interval_s
                time.sleep(max(0.0, next_run - time.monotonic()))
        finally:
            if self.http_server is not None:
                self.http_server.stop()
                self.http_server = None


def _write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    temp = path.with_name(f".{path.name}.tmp")
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"
    temp.write_text(data, encoding="utf-8")
    temp.chmod(0o644)
    temp.replace(path)
