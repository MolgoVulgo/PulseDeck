#!/usr/bin/env bash
# PulseDeck privileged updater worker — git-004
# Root-only fixed-purpose worker triggered by pulsedeck-updater.path.

set -Eeuo pipefail

REQUEST_PATH="/var/lib/pulsedeck-updater/inbox/request.json"
STATUS_DIR="/var/lib/pulsedeck-updater/status"
STATUS_PATH="${STATUS_DIR}/status.json"
MASTER_PATH="/usr/local/sbin/pulsedeck"
RUN_USER="pulsedeck"
RUN_GROUP="pulsedeck"
REQUEST_ID=""
CHANNEL=""

log() { printf '[pulsedeck-updater] %s\n' "$*"; }

write_status() {
  local state="$1" message="${2:-}" exit_code="${3:-}"
  install -d -m 0750 -o root -g "$RUN_GROUP" "$STATUS_DIR"
  python - "$STATUS_PATH" "$state" "$REQUEST_ID" "$CHANNEL" "$message" "$exit_code" <<'PY'
from __future__ import annotations
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time

path = Path(sys.argv[1])
state, request_id, channel, message, exit_code = sys.argv[2:7]
payload = {
    "schema": 1,
    "state": state,
    "request_id": request_id or None,
    "channel": channel or None,
    "message": message or None,
    "updated_at": int(time.time()),
    "updated_at_iso": datetime.now(timezone.utc).isoformat(),
}
if state == "running":
    payload["started_at"] = payload["updated_at"]
if state in {"succeeded", "failed"}:
    payload["finished_at"] = payload["updated_at"]
if exit_code:
    payload["exit_code"] = int(exit_code)
tmp = path.with_name(path.name + ".tmp")
with tmp.open("w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, path)
PY
  chown root:"$RUN_GROUP" "$STATUS_PATH"
  chmod 0640 "$STATUS_PATH"
}

cleanup() {
  rm -f -- "$REQUEST_PATH"
}
trap cleanup EXIT

if (( EUID != 0 )); then
  log "must run as root"
  exit 77
fi

if [[ ! -f "$REQUEST_PATH" || -L "$REQUEST_PATH" ]]; then
  log "request file missing or unsafe"
  exit 66
fi

parsed="$(python - "$REQUEST_PATH" "$RUN_USER" <<'PY'
from __future__ import annotations
import json
import os
from pathlib import Path
import pwd
import re
import stat
import sys
import time

path = Path(sys.argv[1])
expected_user = sys.argv[2]
st = os.lstat(path)
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode):
    raise SystemExit("request is not a regular file")
if st.st_uid != pwd.getpwnam(expected_user).pw_uid:
    raise SystemExit("unexpected request owner")
if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
    raise SystemExit("request is group/world writable")
with path.open("r", encoding="utf-8") as handle:
    data = json.load(handle)
if not isinstance(data, dict):
    raise SystemExit("request must be an object")
expected = {"schema", "action", "channel", "request_id", "requested_at"}
if set(data) != expected:
    raise SystemExit("request fields do not match contract")
if data["schema"] != 1 or data["action"] != "install":
    raise SystemExit("unsupported request contract")
channel = data["channel"]
if channel not in {"stable", "dev"}:
    raise SystemExit("unsupported update channel")
request_id = data["request_id"]
if not isinstance(request_id, str) or re.fullmatch(r"[0-9a-f]{32}", request_id) is None:
    raise SystemExit("invalid request id")
requested_at = data["requested_at"]
if not isinstance(requested_at, int):
    raise SystemExit("invalid request timestamp")
age = int(time.time()) - requested_at
if age < -60 or age > 600:
    raise SystemExit("stale update request")
print(request_id)
print(channel)
PY
)" || {
  write_status "failed" "Invalid privileged update request" "65" || true
  log "request validation failed"
  exit 65
}

REQUEST_ID="$(sed -n '1p' <<<"$parsed")"
CHANNEL="$(sed -n '2p' <<<"$parsed")"
[[ "$REQUEST_ID" =~ ^[0-9a-f]{32}$ ]] || { write_status "failed" "Invalid request id" "65"; exit 65; }
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "dev" ]] || { write_status "failed" "Invalid update channel" "65"; exit 65; }

if [[ ! -x "$MASTER_PATH" || -L "$MASTER_PATH" ]]; then
  write_status "failed" "PulseDeck master launcher is missing or unsafe" "69"
  exit 69
fi
master_owner="$(stat -c '%U' "$MASTER_PATH" 2>/dev/null || true)"
master_mode="$(stat -c '%a' "$MASTER_PATH" 2>/dev/null || true)"
if [[ "$master_owner" != "root" || ! "$master_mode" =~ ^[0-7]{3,4}$ ]]; then
  write_status "failed" "PulseDeck master launcher permissions are unsafe" "69"
  exit 69
fi
mode_bits=$((8#$master_mode))
if (( mode_bits & 022 )); then
  write_status "failed" "PulseDeck master launcher is group/world writable" "69"
  exit 69
fi

write_status "running" "Installing verified ${CHANNEL} channel"
log "starting ${CHANNEL} update request ${REQUEST_ID}"
set +e
"$MASTER_PATH" --channel "$CHANNEL" --hub-only --non-interactive
rc=$?
set -e
if (( rc == 0 )); then
  write_status "succeeded" "PulseDeck ${CHANNEL} update installed" "0"
  log "update request ${REQUEST_ID} succeeded"
  exit 0
fi
write_status "failed" "PulseDeck updater exited with code ${rc}" "$rc"
log "update request ${REQUEST_ID} failed with code ${rc}"
exit "$rc"
