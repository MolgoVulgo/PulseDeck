from __future__ import annotations

from pulsedeck_hub.update import UpdateChecker, parse_semver


def test_parse_semver_accepts_stable_versions() -> None:
    assert parse_semver("0.5.0") == (0, 5, 0)
    assert parse_semver("v12.3.4") == (12, 3, 4)


def test_checker_reports_available_release() -> None:
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

    checker = UpdateChecker("0.5.0", fetcher=fetcher)
    checker.check_once()
    state = checker.snapshot()
    assert state["state"] == "available"
    assert state["latest_version"] == "0.5.1"
    assert state["tag_name"] == "v0.5.1"
    assert state["release_notes"] == "Correctifs runtime"
    assert state["error"] is None


def test_checker_reports_current_release() -> None:
    checker = UpdateChecker(
        "0.5.0",
        fetcher=lambda repository, user_agent, timeout: {
            "tag_name": "v0.5.0",
            "body": "",
            "published_at": None,
        },
    )
    checker.check_once()
    assert checker.snapshot()["state"] == "up_to_date"


def test_checker_failure_is_non_fatal_state() -> None:
    def fetcher(repository: str, user_agent: str, timeout: float):
        raise RuntimeError("network down")

    checker = UpdateChecker("0.5.0", fetcher=fetcher)
    checker.check_once()
    state = checker.snapshot()
    assert state["state"] == "error"
    assert state["error"] == "network down"
    assert state["latest_version"] is None
