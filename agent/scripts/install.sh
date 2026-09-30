#!/usr/bin/env bash
set -euo pipefail

REPO_ARCHIVE_BASE="https://github.com/MolgoVulgo/PulseDeck/archive"
REF="main"
SOURCE=""
NO_START=0
UPGRADE=0

usage() {
    cat <<'USAGE'
Usage: install.sh [--ref REF] [--source /path/to/PulseDeck] [--no-start] [--upgrade]

Installs the standalone PulseDeck Agent under /opt/pulsedeck-agent and creates
/usr/local/bin/pulsedeck-agent. Existing /etc/pulsedeck-agent/agent.yml is preserved.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref) REF="${2:?missing value for --ref}"; shift 2 ;;
        --source) SOURCE="${2:?missing value for --source}"; shift 2 ;;
        --no-start) NO_START=1; shift ;;
        --upgrade) UPGRADE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run the standard installer as root (normally with sudo)." >&2
    exit 2
fi
for cmd in python3 systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 2; }
done

if command -v pacman >/dev/null 2>&1 && [[ -e /usr/bin/pulsedeck-agent ]] && pacman -Qo /usr/bin/pulsedeck-agent >/dev/null 2>&1; then
    echo "An Arch package owns /usr/bin/pulsedeck-agent. Use the makepkg installation/update path instead of mixing methods." >&2
    exit 2
fi

python3 - <<'PY'
import sys
if sys.version_info < (3, 11):
    raise SystemExit("PulseDeck Agent requires Python >= 3.11")
PY

TMP=""
cleanup() { [[ -z "$TMP" ]] || rm -rf "$TMP"; }
trap cleanup EXIT

if [[ -z "$SOURCE" ]]; then
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd || true)"
    candidate="$(cd "$script_dir/../.." >/dev/null 2>&1 && pwd || true)"
    if [[ -n "$candidate" && -f "$candidate/agent/pyproject.toml" ]]; then
        SOURCE="$candidate"
    fi
fi

if [[ -z "$SOURCE" ]]; then
    command -v curl >/dev/null 2>&1 || { echo "curl is required for remote source installation" >&2; exit 2; }
    command -v tar >/dev/null 2>&1 || { echo "tar is required for remote source installation" >&2; exit 2; }
    TMP="$(mktemp -d)"
    archive="$TMP/source.tar.gz"
    curl -fsSL "$REPO_ARCHIVE_BASE/$REF.tar.gz" -o "$archive"
    tar -xzf "$archive" -C "$TMP"
    SOURCE="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'PulseDeck-*' -print -quit)"
fi

[[ -f "$SOURCE/agent/pyproject.toml" ]] || { echo "Invalid PulseDeck source tree: $SOURCE" >&2; exit 2; }

install -d -m 0755 /opt/pulsedeck-agent
if [[ ! -x /opt/pulsedeck-agent/venv/bin/python ]]; then
    python3 -m venv /opt/pulsedeck-agent/venv
fi
/opt/pulsedeck-agent/venv/bin/python -m pip install --disable-pip-version-check --upgrade --force-reinstall "$SOURCE/agent"

install -d -m 0755 /etc/pulsedeck-agent
if [[ ! -e /etc/pulsedeck-agent/agent.yml ]]; then
    install -m 0644 "$SOURCE/agent/config/pulsedeck-agent.example.yml" /etc/pulsedeck-agent/agent.yml
fi

install -m 0644 "$SOURCE/agent/systemd/pulsedeck-agent.service" /etc/systemd/system/pulsedeck-agent.service
install -d -m 0755 /usr/local/libexec/pulsedeck-agent
install -m 0755 "$SOURCE/agent/scripts/install.sh" /usr/local/libexec/pulsedeck-agent/install.sh
install -m 0755 "$SOURCE/agent/scripts/uninstall.sh" /usr/local/libexec/pulsedeck-agent/uninstall.sh
install -m 0755 "$SOURCE/agent/scripts/update.sh" /usr/local/libexec/pulsedeck-agent/update.sh
ln -sfn /opt/pulsedeck-agent/venv/bin/pulsedeck-agent /usr/local/bin/pulsedeck-agent

systemctl daemon-reload
if [[ $NO_START -eq 0 ]]; then
    systemctl enable --now pulsedeck-agent.service
    if [[ $UPGRADE -eq 1 ]]; then
        systemctl restart pulsedeck-agent.service
    fi
fi

/usr/local/bin/pulsedeck-agent --config /etc/pulsedeck-agent/agent.yml config validate
printf 'PulseDeck Agent %s complete.\n' "$([[ $UPGRADE -eq 1 ]] && echo update || echo installation)"
printf 'Config: /etc/pulsedeck-agent/agent.yml\n'
printf 'Status: pulsedeck-agent status\n'
printf 'Update: pulsedeck-agent update\n'
