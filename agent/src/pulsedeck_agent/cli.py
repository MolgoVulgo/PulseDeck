from __future__ import annotations

import argparse
import grp
import json
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

from . import __version__
from .config import DEFAULT_CONFIG_PATH, AgentConfig, ConfigError, load_config
from .http_server import HEALTH_PATH, PROTOCOL_NAME, SNAPSHOT_PATH, WIRE_SCHEMA
from .metadata import InstallInfo, load_install_info
from .runtime import AgentRuntime, DEFAULT_STATE_DIR


SERVICE_NAME = "pulsedeck-agent.service"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pulsedeck-agent")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="YAML configuration path")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("version", help="show Agent version and installed source channel")
    sub.add_parser("check", help="validate configuration and mandatory local collectors")
    sub.add_parser("snapshot", help="print one warmed local diagnostic snapshot as JSON")

    run = sub.add_parser("run", help="run the local collector loop")
    run.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR))

    status = sub.add_parser("status", help="show service and last-snapshot status")
    status.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR))

    doctor = sub.add_parser("doctor", help="verify installation, service, configuration and collectors")
    doctor.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR))

    config = sub.add_parser("config", help="configuration helpers")
    config.add_argument("action", choices=("path", "validate"))

    sub.add_parser("update", help="update the Agent using its installed method and source channel")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "version":
        _print_version(load_install_info())
        return 0
    if args.command == "update":
        return _update()
    if args.command == "config" and args.action == "path":
        print(args.config)
        return 0

    try:
        config = load_config(args.config)
    except ConfigError as exc:
        print(f"PulseDeck Agent configuration error: {exc}", file=sys.stderr)
        return 2

    if args.command == "config":
        print(f"configuration OK: {args.config}")
        return 0

    runtime = AgentRuntime(config)
    if args.command == "snapshot":
        snapshot = runtime.warm_collect(min(config.sample_interval_s, 0.25))
        print(json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True))
        return 0

    if args.command == "check":
        snapshot = runtime.warm_collect(min(config.sample_interval_s, 0.25))
        required_ok = bool(snapshot.get("state", {}).get("ok"))  # type: ignore[union-attr]
        gpu_ok = _gpu_ok(snapshot, config.gpu_enabled)
        print(f"agent={config.agent_id} network={runtime.network.interface} gpu={'on' if config.gpu_enabled else 'off'}")
        if not required_ok:
            print("mandatory collector check failed", file=sys.stderr)
            return 3
        if not gpu_ok:
            print("GPU is enabled but no supported AMD GPU utilization source was found", file=sys.stderr)
            return 4
        print("collector check OK")
        return 0

    if args.command == "run":
        try:
            runtime.run_forever(args.state_dir)
        except KeyboardInterrupt:
            return 0
        return 0

    if args.command == "status":
        return _status(Path(args.state_dir))

    if args.command == "doctor":
        return _doctor(config, runtime, Path(args.state_dir))

    return 2


def _print_version(info: InstallInfo) -> None:
    print(f"PulseDeck Agent {__version__}")
    print(f"install: {info.method}")
    print(f"channel: {info.channel}")
    print(f"revision: {info.revision}")


def _status(state_dir: Path) -> int:
    if shutil.which("systemctl"):
        active = subprocess.run(
            ["systemctl", "is-active", SERVICE_NAME],
            check=False,
            capture_output=True,
            text=True,
        ).stdout.strip()
        print(f"service: {active or 'unknown'}")
    snapshot = state_dir / "snapshot.json"
    if not snapshot.exists():
        print(f"snapshot: missing ({snapshot})")
        return 1
    try:
        data = json.loads(snapshot.read_text(encoding="utf-8"))
        print(f"snapshot: ts={data.get('ts')} ok={data.get('state', {}).get('ok')} agent={data.get('agent', {}).get('id')}")
    except (OSError, json.JSONDecodeError) as exc:
        print(f"snapshot: unreadable: {exc}", file=sys.stderr)
        return 1
    return 0


def _doctor(config: AgentConfig, runtime: AgentRuntime, state_dir: Path) -> int:
    info = load_install_info()
    live = runtime.warm_collect(min(runtime.config.sample_interval_s, 0.25))

    cpu_ok = _metric_valid(live, "cpu", "pct")
    memory_ok = all(_metric_valid(live, "memory", key) for key in ("used_b", "total_b", "pct"))
    network_ok = all(_metric_valid(live, "network", key) for key in ("rx_bytes", "tx_bytes", "rx_bps", "tx_bps"))
    gpu_ok = _gpu_ok(live, runtime.config.gpu_enabled)

    active_ok, active_text = _systemctl_check("is-active", "active", wait_s=10.0)
    enabled_ok, enabled_text = _systemctl_check("is-enabled", "enabled")
    state_dir_ok, state_dir_text = _state_dir_check(state_dir)
    snapshot_ok, snapshot_text = _state_snapshot_check(
        state_dir / "snapshot.json",
        runtime.config.agent_id,
        runtime.config.sample_interval_s,
    )
    if config.transport_enabled and not active_ok:
        transport_ok, transport_text = False, "FAIL (service not active)"
    else:
        transport_ok, transport_text = _transport_check(
            config,
            runtime.config.agent_id,
            runtime.config.sample_interval_s,
            wait_s=10.0,
        )

    install_ok = info.method in {"arch-package", "standalone"}
    channel_ok = info.channel in {"main", "dev"}
    all_ok = all(
        (
            install_ok,
            channel_ok,
            cpu_ok,
            memory_ok,
            network_ok,
            gpu_ok,
            active_ok,
            enabled_ok,
            state_dir_ok,
            snapshot_ok,
            transport_ok,
        )
    )

    print("PulseDeck Agent doctor")
    print()
    print(f"Version       : {__version__}")
    print(f"Install       : {info.method}")
    print(f"Channel       : {info.channel}")
    print(f"Revision      : {info.revision}")
    print(f"Agent ID      : {runtime.config.agent_id}")
    print()
    print("Configuration : OK")
    print(f"CPU           : {'OK' if cpu_ok else 'FAIL'}")
    print(f"Memory        : {'OK' if memory_ok else 'FAIL'}")
    print(f"Network       : {'OK' if network_ok else 'FAIL'} ({runtime.network.interface})")
    if runtime.config.gpu_enabled:
        print(f"GPU           : {'OK' if gpu_ok else 'FAIL'}")
    else:
        print("GPU           : disabled")
    print(f"Service       : {active_text}")
    print(f"Autostart     : {enabled_text}")
    print(f"State dir     : {state_dir_text}")
    print(f"Snapshot      : {snapshot_text}")
    print(f"Transport     : {transport_text}")
    print()
    print(f"Result: {'OK' if all_ok else 'FAILED'}")
    return 0 if all_ok else 6


def _metric_valid(snapshot: dict[str, object], section: str, key: str) -> bool:
    section_value = snapshot.get(section)
    if not isinstance(section_value, dict):
        return False
    metric = section_value.get(key)
    return bool(isinstance(metric, dict) and metric.get("valid"))


def _gpu_ok(snapshot: dict[str, object], enabled: bool) -> bool:
    if not enabled:
        return True
    return _metric_valid(snapshot, "gpu", "pct")


def _systemctl_check(action: str, wanted: str, wait_s: float = 0.0) -> tuple[bool, str]:
    if not shutil.which("systemctl"):
        return False, "unavailable"
    deadline = time.monotonic() + max(0.0, wait_s)
    value = "unknown"
    while True:
        result = subprocess.run(
            ["systemctl", action, SERVICE_NAME],
            check=False,
            capture_output=True,
            text=True,
        )
        value = result.stdout.strip() or result.stderr.strip() or "unknown"
        if result.returncode == 0 and value == wanted:
            return True, value
        if time.monotonic() >= deadline:
            return False, value
        time.sleep(0.25)


def _state_dir_check(path: Path) -> tuple[bool, str]:
    try:
        details = path.stat()
    except OSError as exc:
        return False, f"FAIL ({exc})"
    if not stat.S_ISDIR(details.st_mode):
        return False, "FAIL (not a directory)"

    mode = stat.S_IMODE(details.st_mode)
    try:
        user = pwd.getpwuid(details.st_uid).pw_name
    except KeyError:
        user = str(details.st_uid)
    try:
        group = grp.getgrgid(details.st_gid).gr_name
    except KeyError:
        group = str(details.st_gid)

    owner_ok = user == "pulsedeck-agent" and group == "pulsedeck-agent"
    mode_ok = mode == 0o755
    readable_ok = os.access(path, os.R_OK | os.X_OK)
    if owner_ok and mode_ok and readable_ok:
        return True, f"OK ({user}:{group} {mode:04o})"
    return False, f"FAIL ({user}:{group} {mode:04o})"


def _state_snapshot_check(path: Path, agent_id: str, sample_interval_s: float) -> tuple[bool, str]:
    timeout_s = max(3.0, min(10.0, sample_interval_s * 3.0))
    deadline = time.monotonic() + timeout_s
    last_error = f"missing ({path})"
    while True:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            ts = float(data.get("ts", 0))
            age_s = max(0.0, time.time() - ts)
            state_ok = bool(data.get("state", {}).get("ok"))
            agent_ok = data.get("agent", {}).get("id") == agent_id
            max_age_s = max(10.0, sample_interval_s * 5.0)
            if state_ok and agent_ok and age_s <= max_age_s:
                return True, f"OK (age {age_s:.1f}s)"
            last_error = f"stale/invalid (age {age_s:.1f}s)"
        except FileNotFoundError:
            last_error = f"missing ({path})"
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            last_error = f"unreadable ({exc})"
        if time.monotonic() >= deadline:
            return False, last_error
        time.sleep(0.25)


def _transport_check(
    config: AgentConfig,
    agent_id: str,
    sample_interval_s: float,
    wait_s: float = 0.0,
) -> tuple[bool, str]:
    if not config.transport_enabled:
        return True, "disabled"

    host = "127.0.0.1" if config.transport_listen == "0.0.0.0" else config.transport_listen
    base_url = f"http://{host}:{config.transport_port}"
    deadline = time.monotonic() + max(0.0, wait_s)
    last_error = "unreachable"

    while True:
        try:
            health = _http_json(f"{base_url}{HEALTH_PATH}")
            if health.get("schema") != WIRE_SCHEMA or health.get("state") != "online":
                last_error = "invalid /v1/health response"
            else:
                payload = _http_json(f"{base_url}{SNAPSHOT_PATH}")
                snapshot = payload.get("snapshot")
                if payload.get("schema") != WIRE_SCHEMA or payload.get("protocol") != PROTOCOL_NAME:
                    last_error = "invalid /v1/snapshot envelope"
                elif not isinstance(snapshot, dict):
                    last_error = "invalid /v1/snapshot payload"
                else:
                    try:
                        ts = float(snapshot.get("ts", 0))
                    except (TypeError, ValueError):
                        ts = 0.0
                    age_s = max(0.0, time.time() - ts)
                    state = snapshot.get("state")
                    agent = snapshot.get("agent")
                    capabilities = snapshot.get("capabilities")
                    snapshot_schema_ok = snapshot.get("schema") == 1
                    state_ok = isinstance(state, dict) and bool(state.get("ok"))
                    agent_ok = isinstance(agent, dict) and agent.get("id") == agent_id
                    capabilities_ok = (
                        isinstance(capabilities, list)
                        and {"cpu", "memory", "network"}.issubset(
                            item for item in capabilities if isinstance(item, str)
                        )
                    )
                    max_age_s = max(10.0, sample_interval_s * 5.0)
                    if snapshot_schema_ok and state_ok and agent_ok and capabilities_ok and age_s <= max_age_s:
                        return True, f"OK ({host}:{config.transport_port}; health + snapshot age {age_s:.1f}s)"
                    last_error = f"stale/invalid /v1/snapshot (age {age_s:.1f}s)"
        except (OSError, ValueError, TypeError, json.JSONDecodeError, HTTPError, URLError) as exc:
            last_error = str(exc)

        if time.monotonic() >= deadline:
            return False, f"FAIL ({host}:{config.transport_port}; {last_error})"
        time.sleep(0.25)


def _http_json(url: str) -> dict[str, object]:
    with urlopen(url, timeout=2.0) as response:
        if response.status != 200:
            raise OSError(f"HTTP {response.status}")
        content_type = response.headers.get_content_type()
        if content_type != "application/json":
            raise OSError(f"unexpected content type {content_type}")
        payload = json.loads(response.read().decode("utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("response is not a JSON object")
    return payload


def _update() -> int:
    agent_bin = shutil.which("pulsedeck-agent")
    package_owned = False
    packaged_bin = Path("/usr/bin/pulsedeck-agent")
    if shutil.which("pacman") and packaged_bin.exists():
        package_owned = subprocess.run(
            ["pacman", "-Qo", str(packaged_bin)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
    elif agent_bin and shutil.which("pacman"):
        package_owned = subprocess.run(
            ["pacman", "-Qo", agent_bin],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0

    candidates = (
        Path("/usr/libexec/pulsedeck-agent/update.sh"),
        Path("/usr/local/libexec/pulsedeck-agent/update.sh"),
    ) if package_owned else (
        Path("/usr/local/libexec/pulsedeck-agent/update.sh"),
        Path("/usr/libexec/pulsedeck-agent/update.sh"),
    )
    for script in candidates:
        if script.is_file():
            return subprocess.call([str(script)])
    print("no installed update helper found; install PulseDeck Agent first", file=sys.stderr)
    return 5
