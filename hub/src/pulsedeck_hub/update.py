"""GitHub update discovery for PulseDeck stable and development channels."""

from __future__ import annotations

from collections.abc import Callable
import json
import logging
import os
from pathlib import Path
import re
import secrets
import threading
import time
from typing import Any
import urllib.error
import urllib.parse
import urllib.request


LOG = logging.getLogger(__name__)

DEFAULT_REPOSITORY = "MolgoVulgo/PulseDeck"
DEFAULT_DEV_BRANCH = "dev"
DEFAULT_TIMEOUT = 5.0
MAX_RELEASE_NOTES = 8000
INSTALL_METADATA_PATH = Path("/var/lib/pulsedeck/installer/current.json")
UPDATER_ROOT = Path("/var/lib/pulsedeck-updater")
UPDATE_REQUEST_PATH = UPDATER_ROOT / "inbox" / "request.json"
UPDATE_STATUS_PATH = UPDATER_ROOT / "status" / "status.json"
SEMVER_RE = re.compile(r"^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")

ReleaseFetcher = Callable[[str, str, float], dict[str, Any]]
BranchFetcher = Callable[[str, str, str, float], dict[str, Any]]


def parse_semver(value: str) -> tuple[int, int, int]:
    """Parse a stable X.Y.Z or vX.Y.Z version."""
    match = SEMVER_RE.fullmatch(value.strip())
    if not match:
        raise ValueError(f"Unsupported stable version: {value!r}")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def _github_json(url: str, user_agent: str, timeout: float) -> dict[str, Any]:
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
        raise RuntimeError("GitHub returned an invalid payload")
    return payload


def fetch_latest_release(repository: str, user_agent: str, timeout: float) -> dict[str, Any]:
    """Return the latest stable GitHub Release metadata."""
    payload = _github_json(
        f"https://api.github.com/repos/{repository}/releases/latest",
        user_agent,
        timeout,
    )
    if payload.get("draft") is True or payload.get("prerelease") is True:
        raise RuntimeError("GitHub latest release is not stable")
    return payload


def fetch_branch_head(repository: str, branch: str, user_agent: str, timeout: float) -> dict[str, Any]:
    """Return the commit object currently referenced by a development branch."""
    encoded = urllib.parse.quote(branch, safe="")
    return _github_json(
        f"https://api.github.com/repos/{repository}/commits/{encoded}",
        user_agent,
        timeout,
    )


def load_install_metadata(path: Path = INSTALL_METADATA_PATH) -> dict[str, Any]:
    """Read installer channel metadata. Missing metadata means legacy stable install."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"channel": "stable"}
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        LOG.warning("Unable to read installer metadata %s: %s", path, exc)
        return {"channel": "stable", "metadata_error": str(exc)}
    if not isinstance(payload, dict):
        return {"channel": "stable", "metadata_error": "metadata is not an object"}
    channel = payload.get("channel")
    if channel not in {"stable", "dev", "manual"}:
        return {"channel": "stable", "metadata_error": "unsupported channel metadata"}
    return payload


def load_update_install_status(
    request_path: Path = UPDATE_REQUEST_PATH,
    status_path: Path = UPDATE_STATUS_PATH,
) -> dict[str, Any]:
    """Return the privileged updater state without granting the hub write access to it."""
    status: dict[str, Any] | None = None
    try:
        payload = json.loads(status_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        payload = None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        LOG.warning("Unable to read updater status %s: %s", status_path, exc)
        payload = {"state": "error", "message": "Updater status is unreadable"}
    if isinstance(payload, dict):
        state = payload.get("state")
        if state in {"running", "succeeded", "failed", "error"}:
            status = dict(payload)

    if status is not None and status.get("state") == "running":
        return status

    try:
        request_payload = json.loads(request_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        request_payload = None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        request_payload = {"channel": None, "request_id": None}
    if isinstance(request_payload, dict):
        return {
            "state": "queued",
            "channel": request_payload.get("channel"),
            "request_id": request_payload.get("request_id"),
            "requested_at": request_payload.get("requested_at"),
        }

    return status or {"state": "idle"}


def queue_update_request(
    channel: str,
    request_path: Path = UPDATE_REQUEST_PATH,
) -> dict[str, Any]:
    """Queue one stable/dev install request for the root-owned systemd updater."""
    if channel not in {"stable", "dev"}:
        raise ValueError("Only stable or dev channels can be installed from Web Admin")
    request_dir = request_path.parent
    if not request_dir.is_dir():
        raise RuntimeError("Privileged updater inbox is not installed")
    if request_path.exists():
        raise FileExistsError("An update request is already queued")

    request_id = secrets.token_hex(16)
    payload = {
        "schema": 1,
        "action": "install",
        "channel": channel,
        "request_id": request_id,
        "requested_at": int(time.time()),
    }
    temp_path = request_dir / f".request.{request_id}.tmp"
    fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temp_path, request_path)
        except FileExistsError as exc:
            raise FileExistsError("An update request is already queued") from exc
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
    return payload


class UpdateChecker:
    """Keep a thread-safe snapshot of the selected PulseDeck update channel."""

    def __init__(
        self,
        current_version: str,
        *,
        repository: str = DEFAULT_REPOSITORY,
        timeout: float = DEFAULT_TIMEOUT,
        metadata_path: Path = INSTALL_METADATA_PATH,
        release_fetcher: ReleaseFetcher = fetch_latest_release,
        branch_fetcher: BranchFetcher = fetch_branch_head,
    ) -> None:
        self.current_version = current_version
        self.repository = repository
        self.timeout = timeout
        self.metadata_path = metadata_path
        self._release_fetcher = release_fetcher
        self._branch_fetcher = branch_fetcher
        self._lock = threading.RLock()
        self._checking = False

        metadata = load_install_metadata(metadata_path)
        self.channel = str(metadata.get("channel", "stable"))
        self.branch = str(metadata.get("branch") or DEFAULT_DEV_BRANCH) if self.channel == "dev" else None
        installed_commit = metadata.get("commit")
        self.installed_commit = (
            installed_commit.lower()
            if isinstance(installed_commit, str) and COMMIT_RE.fullmatch(installed_commit.lower())
            else None
        )
        self.resolved_ref = metadata.get("resolved_ref") if isinstance(metadata.get("resolved_ref"), str) else None
        self.metadata_error = metadata.get("metadata_error") if isinstance(metadata.get("metadata_error"), str) else None

        self._state: dict[str, Any] = {
            "state": "idle" if self.channel != "manual" else "manual",
            "channel": self.channel,
            "branch": self.branch,
            "current_version": current_version,
            "installed_commit": self.installed_commit,
            "latest_commit": None,
            "latest_version": None,
            "tag_name": None,
            "release_notes": "",
            "published_at": None,
            "checked_at": None,
            "error": self.metadata_error,
        }

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._state)

    def trigger(self) -> bool:
        """Start a non-blocking check; manual installs intentionally do not auto-track."""
        with self._lock:
            if self.channel == "manual":
                self._state["state"] = "manual"
                self._state["error"] = None
                return False
            if self._checking:
                return False
            self._checking = True
            self._state["state"] = "checking"
            self._state["error"] = None
        threading.Thread(target=self.check_once, name="pulsedeck-update-check", daemon=True).start()
        return True

    def _check_stable(self, checked_at: int) -> None:
        payload = self._release_fetcher(
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
                latest_commit=None,
                release_notes=notes,
                published_at=published_at,
                checked_at=checked_at,
                error=None,
            )
        LOG.info("GitHub release check complete: %s (%s)", tag_name, state)

    def _check_dev(self, checked_at: int) -> None:
        if not self.installed_commit:
            raise RuntimeError("Installed dev commit is unknown")
        branch = self.branch or DEFAULT_DEV_BRANCH
        payload = self._branch_fetcher(
            self.repository,
            branch,
            f"PulseDeck-Hub/{self.current_version}",
            self.timeout,
        )
        latest_commit = payload.get("sha")
        if not isinstance(latest_commit, str) or not COMMIT_RE.fullmatch(latest_commit.lower()):
            raise RuntimeError("GitHub branch returned an invalid commit SHA")
        latest_commit = latest_commit.lower()
        state = "up_to_date" if latest_commit == self.installed_commit else "available"
        with self._lock:
            self._state.update(
                state=state,
                latest_commit=latest_commit,
                latest_version=None,
                tag_name=None,
                release_notes="",
                published_at=None,
                checked_at=checked_at,
                error=None,
            )
        LOG.info(
            "GitHub dev check complete: %s %s -> %s (%s)",
            branch,
            self.installed_commit[:12],
            latest_commit[:12],
            state,
        )

    def check_once(self) -> None:
        """Perform one lookup for the configured channel and update the public snapshot."""
        checked_at = int(time.time())
        try:
            if self.channel == "manual":
                with self._lock:
                    self._state.update(state="manual", checked_at=checked_at, error=None)
                return
            if self.channel == "dev":
                self._check_dev(checked_at)
            else:
                self._check_stable(checked_at)
        except Exception as exc:
            LOG.warning("GitHub %s update check failed: %s", self.channel, exc)
            with self._lock:
                self._state.update(
                    state="error",
                    latest_commit=None,
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
