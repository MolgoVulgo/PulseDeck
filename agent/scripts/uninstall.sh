#!/usr/bin/env bash
set -euo pipefail

PURGE=0
if [[ ${1:-} == "--purge" ]]; then
    PURGE=1
elif [[ $# -gt 0 ]]; then
    echo "Usage: uninstall.sh [--purge]" >&2
    exit 2
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run the standalone uninstaller as root (normally with sudo)." >&2
    exit 2
fi

systemctl disable --now pulsedeck-agent.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/pulsedeck-agent.service
rm -f /usr/local/bin/pulsedeck-agent
rm -rf /usr/local/libexec/pulsedeck-agent
rm -rf /opt/pulsedeck-agent
systemctl daemon-reload

if [[ $PURGE -eq 1 ]]; then
    rm -rf /etc/pulsedeck-agent /var/lib/pulsedeck-agent
else
    echo "Preserved /etc/pulsedeck-agent and /var/lib/pulsedeck-agent (use --purge to remove)."
fi
