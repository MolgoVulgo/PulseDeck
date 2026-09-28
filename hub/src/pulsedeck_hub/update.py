"""GitHub release discovery for PulseDeck Hub updates."""

from __future__ import annotations

from collections.abc import Callable
import json
import logging
import re
import threading
import time
from typing import Any
import urllib.error
import urllib.request


LOG = logging.getLogger(__name__)

DEFAULT_REPOSITORY = "MolgoVulgo/PulseDeck"
DEFAULT_TIMEOUT = 5.0
MAX_RELEASE_NOTES = 8000
SEMVER_RE = re.compile(r"^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")

ReleaseFetcher = Callable[[str, str, float], dict[str, Any]]


def parse_semver(value: str) -> tuple[int, int, int]:
    """Parse a stable X.Y.Z or vX.Y.Z version."""
    match = SEMVER_RE.fullmatch(value.strip())
    if not match:
        raise ValueError(f"Unsupported stable version: {value!r}")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def fetch_latest_release(repository: str, user_agent: str, timeout: float) -> dict[str, Any]:
    """Return the latest stable GitHub Release metadata."""
    url = f"https://api.github.com/repos/{repository}/releases/latest"
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": user_agent,
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"GitHub HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"GitHub unavailable: {exc.reason}") from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError("GitHub returned an invalid JSON response") from exc

    if not isinstance(payload, dict):
        raise RuntimeError("GitHub returned an invalid release payload")
    if payload.get("draft") is True or payload.get("prerelease") is True:
        raise RuntimeError("GitHub latest release is not stable")
    return payload


class UpdateChecker:
    """Keep a thread-safe snapshot of the latest stable GitHub release."""

    def __init__(
        self,
        current_version: str,
        *,
        repository: str = DEFAULT_REPOSITORY,
        timeout: float = DEFAULT_TIMEOUT,
        fetcher: ReleaseFetcher = fetch_latest_release,
    ) -> None:
        parse_semver(current_version)
        self.current_version = current_version
        self.repository = repository
        self.timeout = timeout
        self._fetcher = fetcher
        self._lock = threading.RLock()
        self._checking = False
        self._state: dict[str, Any] = {
            "state": "idle",
            "current_version": current_version,
            "latest_version": None,
            "tag_name": None,
            "release_notes": "",
            "published_at": None,
            "checked_at": None,
            "error": None,
        }

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._state)

    def trigger(self) -> bool:
        """Start a non-blocking check; return False when one is already running."""
        with self._lock:
            if self._checking:
                return False
            self._checking = True
            self._state["state"] = "checking"
            self._state["error"] = None
        threading.Thread(target=self.check_once, name="pulsedeck-update-check", daemon=True).start()
        return True

    def check_once(self) -> None:
        """Perform one release lookup and update the public snapshot."""
        checked_at = int(time.time())
        try:
            payload = self._fetcher(
                self.repository,
                f"PulseDeck-Hub/{self.current_version}",
                self.timeout,
            )
            tag_name = payload.get("tag_name")
            if not isinstance(tag_name, str):
                raise RuntimeError("GitHub release has no valid tag_name")
            latest_tuple = parse_semver(tag_name)
            current_tuple = parse_semver(self.current_version)
            latest_version = tag_name.removeprefix("v")
            notes = payload.get("body")
            if not isinstance(notes, str):
                notes = ""
            if len(notes) > MAX_RELEASE_NOTES:
                notes = notes[:MAX_RELEASE_NOTES] + "\n…"
            published_at = payload.get("published_at")
            if not isinstance(published_at, str):
                published_at = None
            state = "available" if latest_tuple > current_tuple else "up_to_date"
            with self._lock:
                self._state.update(
                    state=state,
                    latest_version=latest_version,
                    tag_name=tag_name,
                    release_notes=notes,
                    published_at=published_at,
                    checked_at=checked_at,
                    error=None,
                )
            LOG.info("GitHub release check complete: %s (%s)", tag_name, state)
        except Exception as exc:
            LOG.warning("GitHub release check failed: %s", exc)
            with self._lock:
                self._state.update(
                    state="error",
                    latest_version=None,
                    tag_name=None,
                    release_notes="",
                    published_at=None,
                    checked_at=checked_at,
                    error=str(exc),
                )
        finally:
            with self._lock:
                self._checking = False
