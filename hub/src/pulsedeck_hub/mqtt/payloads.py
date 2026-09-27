"""Stable payload helpers used by PulseDeck MQTT topics."""

from __future__ import annotations

import json
import time


def encode_payload(payload: dict[str, object]) -> str:
    return json.dumps(payload, separators=(",", ":"), sort_keys=True, ensure_ascii=False)


def availability_payload(
    state: str,
    *,
    session_started: int,
    reason: str | None = None,
    timestamp: int | None = None,
    timestamp_kind: str = "event",
) -> str:
    if state not in {"online", "offline"}:
        raise ValueError(f"unsupported availability state: {state}")
    payload: dict[str, object] = {
        "schema": 1,
        "state": state,
        "ts": int(time.time()) if timestamp is None else int(timestamp),
        "ts_kind": timestamp_kind,
        "session_started": int(session_started),
    }
    if reason:
        payload["reason"] = reason
    return encode_payload(payload)


def source_availability_payload(
    state: str,
    *,
    source: str,
    last_success: int | None = None,
    reason: str | None = None,
) -> str:
    if state not in {"online", "offline"}:
        raise ValueError(f"unsupported availability state: {state}")
    payload: dict[str, object] = {
        "schema": 1,
        "source": source,
        "state": state,
        "ts": int(time.time()),
    }
    if last_success is not None:
        payload["last_success"] = int(last_success)
    if reason:
        payload["reason"] = reason
    return encode_payload(payload)
