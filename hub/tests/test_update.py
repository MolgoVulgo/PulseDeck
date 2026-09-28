from __future__ import annotations

import json
from pathlib import Path

from pulsedeck_hub.update import UpdateChecker, load_install_metadata, parse_semver


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
