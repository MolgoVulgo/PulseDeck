#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/MolgoVulgo/PulseDeck.git"
SERVICE="pulsedeck-agent.service"

usage() {
    cat <<'USAGE'
Usage: install.sh [main|dev]

Installs or reinstalls PulseDeck Agent from a clean remote checkout.
If no channel is given and this script is executed from a PulseDeck checkout,
the current main/dev branch is used; otherwise main is used.
USAGE
}

fail() {
    printf 'PulseDeck Agent install: %s\n' "$*" >&2
    exit 2
}

show_diagnostics() {
    printf '\n--- PulseDeck Agent service status ---\n' >&2
    sudo systemctl status "$SERVICE" --no-pager >&2 2>&1 || true
    printf '\n--- PulseDeck Agent recent journal ---\n' >&2
    sudo journalctl -u "$SERVICE" -n 40 --no-pager >&2 2>&1 || true
    printf '\n--- PulseDeck Agent installed identity ---\n' >&2
    pulsedeck-agent version >&2 2>&1 || true
}

if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

REF="${1:-}"
if [[ "$REF" == "-h" || "$REF" == "--help" ]]; then
    usage
    exit 0
fi

if [[ -z "$REF" ]]; then
    current_branch=""
    script_path="${BASH_SOURCE[0]:-}"
    if [[ -n "$script_path" && -f "$script_path" ]]; then
        script_dir="$(cd -- "$(dirname -- "$script_path")" >/dev/null 2>&1 && pwd || true)"
        if [[ -n "$script_dir" ]]; then
            current_branch="$(git -C "$script_dir" branch --show-current 2>/dev/null || true)"
        fi
    fi
    case "$current_branch" in
        main|dev) REF="$current_branch" ;;
        *) REF="main" ;;
    esac
fi

case "$REF" in
    main|dev) ;;
    *) fail "unsupported channel '$REF' (expected main or dev)" ;;
esac

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    fail "run this installer as a regular user; it uses sudo only for system changes"
fi

for cmd in sudo pacman systemctl mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: $cmd"
done

# Ask for sudo once, near the beginning, so makepkg/pacman and service setup do
# not prompt unpredictably later in the installation.
sudo -v

# The installer is intentionally allowed to satisfy its own Arch build tooling.
# This is an explicit user-invoked installation path, not an automatic validation.
if ! command -v makepkg >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm base-devel
fi
if ! command -v git >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm git
fi

command -v makepkg >/dev/null 2>&1 || fail "makepkg is unavailable after installing base-devel"
command -v git >/dev/null 2>&1 || fail "git is unavailable after installation"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

printf 'PulseDeck Agent channel : %s\n' "$REF"
printf 'Fetching clean source  : %s\n' "$REPO"

git clone --quiet --depth 1 --branch "$REF" "$REPO" "$TMP/PulseDeck" \
    || fail "cannot fetch PulseDeck channel '$REF'"
REVISION="$(git -C "$TMP/PulseDeck" rev-parse HEAD)"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve source revision"

BUILD_DIR="$TMP/PulseDeck/agent/packaging/arch"
[[ -f "$BUILD_DIR/PKGBUILD" ]] || fail "downloaded source does not contain the Arch PKGBUILD"

printf 'Source revision       : %s\n' "$REVISION"
printf 'Building clean package...\n'
cd "$BUILD_DIR"
PULSEDECK_REF="$REF" PULSEDECK_COMMIT="$REVISION" makepkg -Csi --noconfirm

[[ -x /usr/libexec/pulsedeck-agent/prepare-state.sh ]] \
    || fail "installed package is incomplete: prepare-state.sh is missing"
[[ -r /usr/lib/sysusers.d/pulsedeck-agent.conf ]] \
    || fail "installed package is incomplete: sysusers definition is missing"

sudo /usr/libexec/pulsedeck-agent/prepare-state.sh
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE" >/dev/null
sudo systemctl restart "$SERVICE"

if ! pulsedeck-agent doctor; then
    show_diagnostics
    printf '\nPulseDeck Agent installation failed its final health check.\n' >&2
    exit 6
fi

printf '\nPulseDeck Agent installation complete.\n'
pulsedeck-agent version
