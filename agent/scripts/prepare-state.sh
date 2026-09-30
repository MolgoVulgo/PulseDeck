#!/usr/bin/env bash
set -euo pipefail

SERVICE="pulsedeck-agent.service"
STATE_DIR="/var/lib/pulsedeck-agent"
PRIVATE_STATE_DIR="/var/lib/private/pulsedeck-agent"
SYSUSERS_FILE="/usr/lib/sysusers.d/pulsedeck-agent.conf"
SERVICE_USER="pulsedeck-agent"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "prepare-state.sh must run as root." >&2
    exit 2
fi

for cmd in systemctl systemd-sysusers install chown chmod readlink; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 2; }
done

[[ -r "$SYSUSERS_FILE" ]] || { echo "Missing sysusers definition: $SYSUSERS_FILE" >&2; exit 2; }
systemd-sysusers "$SYSUSERS_FILE"

# The pre-agent-003-1 service used DynamicUser=yes. systemd therefore mapped
# StateDirectory through /var/lib/private, which a normal user cannot traverse.
# snapshot.json is diagnostic state only, so the old private state can be dropped.
systemctl stop "$SERVICE" >/dev/null 2>&1 || true
if [[ -L "$STATE_DIR" ]]; then
    resolved="$(readlink -f "$STATE_DIR" || true)"
    if [[ "$resolved" != "$PRIVATE_STATE_DIR" ]]; then
        echo "Refusing to replace unexpected state-directory symlink: $STATE_DIR -> ${resolved:-unknown}" >&2
        exit 2
    fi
    rm -f "$STATE_DIR"
    rm -rf "$PRIVATE_STATE_DIR"
fi

install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$STATE_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$STATE_DIR"
chmod 0755 "$STATE_DIR"
