from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


DEFAULT_METADATA_DIRS: tuple[Path, ...] = (
    Path("/usr/share/pulsedeck-agent"),
    Path("/usr/local/share/pulsedeck-agent"),
)


@dataclass(frozen=True)
class InstallInfo:
    method: str
    channel: str
    revision: str


def load_install_info(metadata_dirs: tuple[Path, ...] = DEFAULT_METADATA_DIRS) -> InstallInfo:
    for directory in metadata_dirs:
        method = _read(directory / "install-method")
        channel = _read(directory / "source-ref")
        revision = _read(directory / "source-revision")
        if method or channel or revision:
            return InstallInfo(
                method=method or "unknown",
                channel=channel or "unknown",
                revision=revision or "unknown",
            )
    return InstallInfo(method="unmanaged", channel="unknown", revision="unknown")


def _read(path: Path) -> str | None:
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return value or None
