#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/MolgoVulgo/PulseDeck.git"
RAW_BASE="https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main"

agent_bin="$(command -v pulsedeck-agent || true)"
if [[ -n "$agent_bin" ]] && command -v pacman >/dev/null 2>&1 && pacman -Qo "$agent_bin" >/dev/null 2>&1; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        echo "Arch package updates must run as a regular user because makepkg refuses root." >&2
        exit 2
    fi
    for cmd in makepkg git; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 2; }
    done
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git clone --depth 1 "$REPO" "$tmp/PulseDeck"
    cd "$tmp/PulseDeck/agent/packaging/arch"
    makepkg -si
    sudo systemctl restart pulsedeck-agent.service
    systemctl is-active --quiet pulsedeck-agent.service
    echo "PulseDeck Agent Arch package update complete."
    exit 0
fi

installer="/usr/local/libexec/pulsedeck-agent/install.sh"
if [[ ! -x "$installer" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
        echo "Standalone update helper is missing and curl is unavailable." >&2
        exit 2
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "$RAW_BASE/agent/scripts/install.sh" -o "$tmp/install.sh"
    chmod +x "$tmp/install.sh"
    installer="$tmp/install.sh"
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    exec sudo "$installer" --upgrade
fi
exec "$installer" --upgrade
