#!/usr/bin/env python3
"""Keep scripts/deploy_hub.sh embedded payload aligned with repository sources."""

from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
import gzip
import hashlib
import io
import os
from pathlib import Path
import tarfile
import tempfile
import textwrap

MARKER = b"\n__PULSEDECK_PAYLOAD__\n"
DEPLOY_SCRIPT = Path("scripts/deploy_hub.sh")


@dataclass(frozen=True)
class PayloadFile:
    source: Path
    target: str
    mode: int = 0o644


def _repo_root(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    return Path(__file__).resolve().parents[1]


def _is_source_file(path: Path) -> bool:
    parts = set(path.parts)
    if "__pycache__" in parts or ".pytest_cache" in parts:
        return False
    if path.name.endswith((".pyc", ".pyo")):
        return False
    return path.is_file()


def payload_files(root: Path) -> list[PayloadFile]:
    files: list[PayloadFile] = []

    pyproject = root / "hub/pyproject.toml"
    files.append(PayloadFile(pyproject, "hub/pyproject.toml"))

    package_root = root / "hub/src/pulsedeck_hub"
    if not package_root.is_dir():
        raise FileNotFoundError(f"missing hub package directory: {package_root}")
    for source in sorted(p for p in package_root.rglob("*") if _is_source_file(p)):
        files.append(PayloadFile(source, source.relative_to(root).as_posix()))

    # Kept for parity with the existing standalone payload and updater validation.
    update_test = root / "hub/tests/test_update.py"
    if update_test.is_file():
        files.append(PayloadFile(update_test, "hub/tests/test_update.py"))

    fixed = [
        ("config/pulsedeck.example.toml", "pulsedeck.toml.in", 0o644),
        ("systemd/pulsedeck-hub.service", "pulsedeck-hub.service", 0o644),
        ("systemd/pulsedeck-updater.service", "pulsedeck-updater.service", 0o644),
        ("systemd/pulsedeck-updater.path", "pulsedeck-updater.path", 0o644),
        ("scripts/pulsedeck-updater.sh", "pulsedeck-updater.sh", 0o755),
        ("scripts/pulsedeck.sh", "pulsedeck.sh", 0o755),
    ]
    for source_name, target, mode in fixed:
        files.append(PayloadFile(root / source_name, target, mode))

    missing = [str(item.source.relative_to(root)) for item in files if not item.source.is_file()]
    if missing:
        raise FileNotFoundError("missing payload source(s): " + ", ".join(missing))

    targets = [item.target for item in files]
    duplicates = sorted({name for name in targets if targets.count(name) > 1})
    if duplicates:
        raise ValueError("duplicate payload target(s): " + ", ".join(duplicates))
    return sorted(files, key=lambda item: item.target)


def source_map(root: Path) -> dict[str, bytes]:
    return {item.target: item.source.read_bytes() for item in payload_files(root)}


def build_payload(root: Path) -> bytes:
    buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=buffer, mode="wb", compresslevel=9, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as archive:
            for item in payload_files(root):
                data = item.source.read_bytes()
                info = tarfile.TarInfo(item.target)
                info.size = len(data)
                info.mode = item.mode
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                info.mtime = 0
                archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def render_script(root: Path) -> bytes:
    script_path = root / DEPLOY_SCRIPT
    current = script_path.read_bytes()
    head, sep, _payload = current.partition(MARKER)
    if not sep:
        raise ValueError(f"payload marker missing from {DEPLOY_SCRIPT}")
    encoded = base64.b64encode(build_payload(root)).decode("ascii")
    wrapped = "\n".join(textwrap.wrap(encoded, 76)).encode("ascii") + b"\n"
    return head + MARKER + wrapped


def embedded_map(script_bytes: bytes) -> dict[str, bytes]:
    _head, sep, encoded = script_bytes.partition(MARKER)
    if not sep:
        raise ValueError("payload marker missing")
    try:
        compressed = base64.b64decode(b"".join(encoded.split()), validate=True)
    except Exception as exc:  # noqa: BLE001 - diagnostic boundary
        raise ValueError(f"embedded payload is not valid base64: {exc}") from exc
    result: dict[str, bytes] = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(compressed), mode="r:gz") as archive:
            for member in archive.getmembers():
                if not member.isfile():
                    continue
                name = member.name[2:] if member.name.startswith("./") else member.name
                if name.startswith("/") or ".." in Path(name).parts:
                    raise ValueError(f"unsafe embedded payload path: {member.name}")
                handle = archive.extractfile(member)
                if handle is None:
                    raise ValueError(f"cannot read embedded payload file: {member.name}")
                result[name] = handle.read()
    except (tarfile.TarError, OSError) as exc:
        raise ValueError(f"embedded payload is not a valid tar.gz: {exc}") from exc
    return result


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:12]


def describe_drift(root: Path, current: bytes) -> list[str]:
    expected = source_map(root)
    try:
        actual = embedded_map(current)
    except ValueError as exc:
        return [str(exc)]
    lines: list[str] = []
    for name in sorted(expected.keys() - actual.keys()):
        lines.append(f"missing in payload: {name}")
    for name in sorted(actual.keys() - expected.keys()):
        lines.append(f"extra in payload: {name}")
    for name in sorted(expected.keys() & actual.keys()):
        if expected[name] != actual[name]:
            lines.append(f"content differs: {name} ({_digest(actual[name])} != {_digest(expected[name])})")
    return lines


def atomic_write(path: Path, data: bytes) -> None:
    mode = path.stat().st_mode & 0o777
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", help="repository root (defaults to script parent repository)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="fail if the embedded payload is stale (default)")
    mode.add_argument("--write", action="store_true", help="rewrite deploy_hub.sh if the payload is stale")
    args = parser.parse_args()

    root = _repo_root(args.root)
    script_path = root / DEPLOY_SCRIPT
    current = script_path.read_bytes()
    expected = render_script(root)
    if current == expected:
        print("deploy_hub payload: current")
        return 0

    drift = describe_drift(root, current)
    if not drift:
        drift = ["archive encoding/metadata differs from deterministic payload"]
    if args.write:
        atomic_write(script_path, expected)
        print(f"deploy_hub payload: refreshed ({len(drift)} drift item(s))")
        for line in drift[:20]:
            print(f" - {line}")
        if len(drift) > 20:
            print(f" - ... {len(drift) - 20} more")
        return 0

    print("deploy_hub payload: STALE")
    for line in drift[:20]:
        print(f" - {line}")
    if len(drift) > 20:
        print(f" - ... {len(drift) - 20} more")
    print("Run: python scripts/sync_deploy_payload.py --write")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
