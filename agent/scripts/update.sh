#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/MolgoVulgo/PulseDeck.git"

read_ref() {
    local path value
    for path in /usr/share/pulsedeck-agent/source-ref /usr/local/share/pulsedeck-agent/source-ref; do
        if [[ -r "$path" ]]; then
            value="$(tr -d '[:space:]' < "$path")"
            case "$value" in
                main|dev) printf '%s\n' "$value"; return 0 ;;
                *) echo "Invalid installed PulseDeck Agent channel in $path: $value" >&2; return 2 ;;
            esac
        fi
    done
    printf '%s\n' main
}

REF="$(read_ref)"
RAW_BASE="https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/$REF"

agent_bin="$(command -v pulsedeck-agent || true)"
if [[ -n "$agent_bin" ]] && command -v pacman >/dev/null 2>&1 && pacman -Qo "$agent_bin" >/dev/null 2>&1; then
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        echo "Arch package updates must run as a regular user because makepkg refuses root." >&2
        exit 2
    fi
    for cmd in makepkg git sudo; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 2; }
    done
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git clone --depth 1 --branch "$REF" "$REPO" "$tmp/PulseDeck"
    cd "$tmp/PulseDeck/agent/packaging/arch"
    PULSEDECK_REF="$REF" makepkg -Csi
    sudo /usr/libexec/pulsedeck-agent/prepare-state.sh
    sudo systemctl daemon-reload
    sudo systemctl restart pulsedeck-agent.service
    pulsedeck-agent doctor
    echo "PulseDeck Agent Arch package update complete (channel: $REF)."
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
    exec sudo "$installer" --ref "$REF" --upgrade
fi
exec "$installer" --ref "$REF" --upgrade
