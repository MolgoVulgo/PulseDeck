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

    helper="/usr/share/pulsedeck-agent/arch/install.sh"
    if [[ -x "$helper" ]]; then
        exec "$helper" "$REF"
    fi

    # Compatibility fallback for an older/incomplete package: fetch a clean copy
    # of the selected channel and use its Arch installer. No local checkout is used.
    for cmd in git mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 2; }
    done
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git clone --quiet --depth 1 --branch "$REF" "$REPO" "$tmp/PulseDeck"
    exec "$tmp/PulseDeck/agent/packaging/arch/install.sh" "$REF"
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
