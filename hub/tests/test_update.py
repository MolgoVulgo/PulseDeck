from __future__ import annotations

import json
from pathlib import Path
import stat

import pytest

from pulsedeck_hub.update import (
    UpdateChecker,
    load_install_metadata,
    load_update_install_status,
    parse_semver,
    queue_update_request,
)


DEV_SHA = "1" * 40
NEW_DEV_SHA = "2" * 40


def write_metadata(path: Path, **values) -> None:
    data = {
        "schema": 1,
        "repository": "MolgoVulgo/PulseDeck",
        "channel": "dev",
        "branch": "dev",
        "resolved_ref": "dev",
        "commit": DEV_SHA,
        "version": "0.6.0.dev0",
    }
    data.update(values)
    path.write_text(json.dumps(data), encoding="utf-8")


def test_parse_semver_accepts_stable_versions() -> None:
    assert parse_semver("0.5.0") == (0, 5, 0)
    assert parse_semver("v12.3.4") == (12, 3, 4)


def test_missing_metadata_defaults_to_stable(tmp_path: Path) -> None:
    metadata = load_install_metadata(tmp_path / "missing.json")
    assert metadata == {"channel": "stable"}


def test_stable_checker_reports_available_release(tmp_path: Path) -> None:
    def fetcher(repository: str, user_agent: str, timeout: float):
        assert repository == "MolgoVulgo/PulseDeck"
        assert user_agent == "PulseDeck-Hub/0.5.0"
        assert timeout == 5.0
        return {
            "tag_name": "v0.5.1",
            "body": "Correctifs runtime",
            "published_at": "2026-09-28T12:00:00Z",
            "draft": False,
            "prerelease": False,
        }

    checker = UpdateChecker(
        "0.5.0",
        metadata_path=tmp_path / "missing.json",
        release_fetcher=fetcher,
    )
    checker.check_once()
    state = checker.snapshot()
    assert state["channel"] == "stable"
    assert state["state"] == "available"
    assert state["latest_version"] == "0.5.1"
    assert state["tag_name"] == "v0.5.1"
    assert state["release_notes"] == "Correctifs runtime"
    assert state["error"] is None


def test_stable_checker_reports_current_release(tmp_path: Path) -> None:
    checker = UpdateChecker(
        "0.5.0",
        metadata_path=tmp_path / "missing.json",
        release_fetcher=lambda repository, user_agent, timeout: {
            "tag_name": "v0.5.0",
            "body": "",
            "published_at": None,
        },
    )
    checker.check_once()
    assert checker.snapshot()["state"] == "up_to_date"


def test_dev_checker_reports_new_commit(tmp_path: Path) -> None:
    metadata_path = tmp_path / "current.json"
    write_metadata(metadata_path)

    def branch_fetcher(repository: str, branch: str, user_agent: str, timeout: float):
        assert repository == "MolgoVulgo/PulseDeck"
        assert branch == "dev"
        assert user_agent == "PulseDeck-Hub/0.6.0.dev0"
        assert timeout == 5.0
        return {"sha": NEW_DEV_SHA}

    checker = UpdateChecker(
        "0.6.0.dev0",
        metadata_path=metadata_path,
        branch_fetcher=branch_fetcher,
    )
    checker.check_once()
    state = checker.snapshot()
    assert state["channel"] == "dev"
    assert state["branch"] == "dev"
    assert state["installed_commit"] == DEV_SHA
    assert state["latest_commit"] == NEW_DEV_SHA
    assert state["state"] == "available"
    assert state["latest_version"] is None


def test_dev_checker_reports_current_commit(tmp_path: Path) -> None:
    metadata_path = tmp_path / "current.json"
    write_metadata(metadata_path)
    checker = UpdateChecker(
        "0.6.0.dev0",
        metadata_path=metadata_path,
        branch_fetcher=lambda repository, branch, user_agent, timeout: {"sha": DEV_SHA},
    )
    checker.check_once()
    assert checker.snapshot()["state"] == "up_to_date"


def test_dev_checker_requires_installed_commit(tmp_path: Path) -> None:
    metadata_path = tmp_path / "current.json"
    write_metadata(metadata_path, commit=None)
    checker = UpdateChecker(
        "0.6.0.dev0",
        metadata_path=metadata_path,
        branch_fetcher=lambda repository, branch, user_agent, timeout: {"sha": NEW_DEV_SHA},
    )
    checker.check_once()
    state = checker.snapshot()
    assert state["state"] == "error"
    assert state["error"] == "Installed dev commit is unknown"


def test_manual_channel_disables_automatic_check(tmp_path: Path) -> None:
    metadata_path = tmp_path / "current.json"
    write_metadata(metadata_path, channel="manual", branch=None)
    checker = UpdateChecker("0.6.0.dev0", metadata_path=metadata_path)
    assert checker.snapshot()["state"] == "manual"
    assert checker.trigger() is False
    assert checker.snapshot()["state"] == "manual"


def test_checker_failure_is_non_fatal_state(tmp_path: Path) -> None:
    def fetcher(repository: str, user_agent: str, timeout: float):
        raise RuntimeError("network down")

    checker = UpdateChecker(
        "0.5.0",
        metadata_path=tmp_path / "missing.json",
        release_fetcher=fetcher,
    )
    checker.check_once()
    state = checker.snapshot()
    assert state["state"] == "error"
    assert state["error"] == "network down"
    assert state["latest_version"] is None


def test_queue_update_request_is_atomic_and_channel_scoped(tmp_path: Path) -> None:
    inbox = tmp_path / "inbox"
    inbox.mkdir()
    request_path = inbox / "request.json"

    payload = queue_update_request("dev", request_path=request_path)

    stored = json.loads(request_path.read_text(encoding="utf-8"))
    assert stored == payload
    assert stored["schema"] == 1
    assert stored["action"] == "install"
    assert stored["channel"] == "dev"
    assert len(stored["request_id"]) == 32
    assert stat.S_IMODE(request_path.stat().st_mode) == 0o640
    assert list(inbox.glob(".request.*.tmp")) == []

    with pytest.raises(FileExistsError):
        queue_update_request("dev", request_path=request_path)


def test_queue_update_request_rejects_manual_channel(tmp_path: Path) -> None:
    inbox = tmp_path / "inbox"
    inbox.mkdir()
    with pytest.raises(ValueError):
        queue_update_request("manual", request_path=inbox / "request.json")


def test_install_status_reports_queue_then_root_result(tmp_path: Path) -> None:
    request_path = tmp_path / "inbox" / "request.json"
    status_path = tmp_path / "status" / "status.json"
    request_path.parent.mkdir()
    status_path.parent.mkdir()

    queued = queue_update_request("stable", request_path=request_path)
    state = load_update_install_status(request_path=request_path, status_path=status_path)
    assert state["state"] == "queued"
    assert state["request_id"] == queued["request_id"]
    assert state["channel"] == "stable"

    request_path.unlink()
    status_path.write_text(
        json.dumps(
            {
                "schema": 1,
                "state": "succeeded",
                "request_id": queued["request_id"],
                "channel": "stable",
                "message": "Update installed",
            }
        ),
        encoding="utf-8",
    )
    state = load_update_install_status(request_path=request_path, status_path=status_path)
    assert state["state"] == "succeeded"
    assert state["request_id"] == queued["request_id"]


def test_running_root_status_wins_over_request_file(tmp_path: Path) -> None:
    request_path = tmp_path / "inbox" / "request.json"
    status_path = tmp_path / "status" / "status.json"
    request_path.parent.mkdir()
    status_path.parent.mkdir()
    queued = queue_update_request("dev", request_path=request_path)
    status_path.write_text(
        json.dumps(
            {
                "schema": 1,
                "state": "running",
                "request_id": queued["request_id"],
                "channel": "dev",
                "message": "Update in progress",
            }
        ),
        encoding="utf-8",
    )
    state = load_update_install_status(request_path=request_path, status_path=status_path)
    assert state["state"] == "running"
    assert state["request_id"] == queued["request_id"]
