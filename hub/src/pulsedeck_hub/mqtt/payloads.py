"""Small stable payloads used by hub-level MQTT topics."""

from __future__ import annotations

import json
import time


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
    return json.dumps(payload, separators=(",", ":"), sort_keys=True)
