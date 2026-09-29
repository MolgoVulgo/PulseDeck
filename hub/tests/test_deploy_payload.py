"""Regression guard for the runtime payload embedded in deploy_hub.sh."""

from __future__ import annotations

import base64
import io
from pathlib import Path
import tarfile


ROOT = Path(__file__).resolve().parents[2]
DEPLOY_SCRIPT = ROOT / "scripts" / "deploy_hub.sh"
PAYLOAD_MARKER = b"\n__PULSEDECK_PAYLOAD__\n"


def _embedded_runtime_files() -> dict[str, bytes]:
    raw = DEPLOY_SCRIPT.read_bytes()
    assert raw.count(PAYLOAD_MARKER) == 1, "deploy_hub.sh must contain exactly one payload marker"
    encoded = raw.split(PAYLOAD_MARKER, 1)[1]
    archive = base64.b64decode(b"".join(encoded.split()), validate=True)

    files: dict[str, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
        for member in bundle.getmembers():
            if not member.isfile():
                continue
            name = member.name.removeprefix("./")
            if name == "hub/pyproject.toml" or name.startswith("hub/src/pulsedeck_hub/"):
                handle = bundle.extractfile(member)
                assert handle is not None
                assert name not in files, f"duplicate embedded path: {name}"
                files[name] = handle.read()
    return files


def test_deploy_payload_matches_runtime_sources() -> None:
    embedded = _embedded_runtime_files()
    expected_paths = {"hub/pyproject.toml"}
    expected_paths.update(
        path.relative_to(ROOT).as_posix()
        for path in (ROOT / "hub" / "src" / "pulsedeck_hub").rglob("*")
        if path.is_file()
    )

    assert set(embedded) == expected_paths
    for relative_path in sorted(expected_paths):
        assert embedded[relative_path] == (ROOT / relative_path).read_bytes(), relative_path
