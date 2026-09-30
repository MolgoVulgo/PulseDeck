#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./install.sh [main|dev]

Without an argument, the script uses the current Git branch when it is main or dev;
otherwise it defaults to main.
USAGE
}

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REF="${1:-}"

if [[ -z "$REF" ]]; then
    repo_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    current_branch=""
    if [[ -n "$repo_root" ]]; then
        current_branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
    fi
    case "$current_branch" in
        main|dev) REF="$current_branch" ;;
        *) REF="main" ;;
    esac
fi

case "$REF" in
    main|dev) ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "Unsupported PulseDeck Agent channel: $REF" >&2
        usage >&2
        exit 2
        ;;
esac

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "Run this installer as a regular user; makepkg must not run as root." >&2
    exit 2
fi

for cmd in makepkg git sudo systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 2; }
done

cd "$SCRIPT_DIR"
printf 'PulseDeck Agent channel: %s\n' "$REF"
PULSEDECK_REF="$REF" makepkg -Csi
sudo systemctl enable --now pulsedeck-agent.service
pulsedeck-agent doctor
