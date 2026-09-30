from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

from . import __version__
from .config import DEFAULT_CONFIG_PATH, ConfigError, load_config
from .runtime import AgentRuntime, DEFAULT_STATE_DIR


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pulsedeck-agent")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="YAML configuration path")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("version", help="show Agent version")
    sub.add_parser("check", help="validate configuration and mandatory local collectors")
    sub.add_parser("snapshot", help="print one warmed local diagnostic snapshot as JSON")

    run = sub.add_parser("run", help="run the local collector loop")
    run.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR))

    status = sub.add_parser("status", help="show service and last-snapshot status")
    status.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR))

    config = sub.add_parser("config", help="configuration helpers")
    config.add_argument("action", choices=("path", "validate"))

    sub.add_parser("update", help="update the Agent using its installed method")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "version":
        print(__version__)
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
        gpu_ok = True
        if config.gpu_enabled:
            gpu = snapshot.get("gpu", {})
            gpu_ok = bool(isinstance(gpu, dict) and gpu.get("pct", {}).get("valid"))  # type: ignore[union-attr]
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

    return 2


def _status(state_dir: Path) -> int:
    if shutil.which("systemctl"):
        active = subprocess.run(
            ["systemctl", "is-active", "pulsedeck-agent.service"],
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
