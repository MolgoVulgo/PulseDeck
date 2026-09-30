#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/MolgoVulgo/PulseDeck.git"
SERVICE="pulsedeck-agent.service"
TMP=""
SUDO_KEEPALIVE_PID=""

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

cleanup() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
        wait "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMP" ]]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

sudo_run() {
    sudo -n "$@" || fail "sudo authorization is no longer available; rerun the installer"
}

show_diagnostics() {
    printf '\n--- PulseDeck Agent service status ---\n' >&2
    sudo -n systemctl status "$SERVICE" --no-pager >&2 2>&1 || true
    printf '\n--- PulseDeck Agent recent journal ---\n' >&2
    sudo -n journalctl -u "$SERVICE" -n 40 --no-pager >&2 2>&1 || true
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

for cmd in sudo pacman systemctl mktemp sed find; do
    command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: $cmd"
done

# Authenticate once. Every later privileged operation uses sudo -n; a small
# keepalive refreshes the same credential while makepkg is running.
sudo -v || fail "sudo authentication failed"
(
    while sleep 30; do
        sudo -n true >/dev/null 2>&1 || exit 0
    done
) &
SUDO_KEEPALIVE_PID=$!

# The installer is intentionally allowed to satisfy its own Arch build tooling.
# This is an explicit user-invoked installation path, not an automatic validation.
if ! command -v makepkg >/dev/null 2>&1; then
    sudo_run pacman -S --needed --noconfirm base-devel
fi
if ! command -v git >/dev/null 2>&1; then
    sudo_run pacman -S --needed --noconfirm git
fi

command -v makepkg >/dev/null 2>&1 || fail "makepkg is unavailable after installing base-devel"
command -v git >/dev/null 2>&1 || fail "git is unavailable after installation"

TMP="$(mktemp -d)"
printf 'PulseDeck Agent channel : %s\n' "$REF"
printf 'Fetching clean source  : %s\n' "$REPO"

git clone --quiet --depth 1 --branch "$REF" "$REPO" "$TMP/PulseDeck" \
    || fail "cannot fetch PulseDeck channel '$REF'"
REVISION="$(git -C "$TMP/PulseDeck" rev-parse HEAD)"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve source revision"

BUILD_DIR="$TMP/PulseDeck/agent/packaging/arch"
[[ -f "$BUILD_DIR/PKGBUILD" ]] || fail "downloaded source does not contain the Arch PKGBUILD"

printf 'Source revision       : %s\n' "$REVISION"
cd "$BUILD_DIR"

# Let makepkg resolve package dependencies, but force its pacman calls through
# the already-authenticated non-interactive sudo session. Package installation
# itself is deliberately kept outside makepkg.
PACMAN_BIN="$(command -v pacman)"
PACMAN_WRAPPER="$TMP/pacman-sudo"
cat > "$PACMAN_WRAPPER" <<EOF
#!/usr/bin/env bash
exec sudo -n "$PACMAN_BIN" "\$@"
EOF
chmod 0755 "$PACMAN_WRAPPER"

printf 'Building clean package...\n'
MAKEPKG_STDERR="$TMP/makepkg.stderr"
set +e
PACMAN="$PACMAN_WRAPPER" PULSEDECK_REF="$REF" PULSEDECK_COMMIT="$REVISION" \
    makepkg -Cs --noconfirm 2>"$MAKEPKG_STDERR"
MAKEPKG_RC=$?
set -e

if [[ $MAKEPKG_RC -ne 0 ]]; then
    [[ ! -s "$MAKEPKG_STDERR" ]] || cat "$MAKEPKG_STDERR" >&2
    fail "makepkg failed with exit code $MAKEPKG_RC"
fi

# Current fakeroot versions can emit this exact harmless line after a successful
# package build. Hide only that line on success; all other stderr remains visible.
if [[ -s "$MAKEPKG_STDERR" ]]; then
    sed '/^libfakeroot internal error: payload not recognized!$/d' "$MAKEPKG_STDERR" >&2
fi

mapfile -t built_packages < <(
    find "$BUILD_DIR" -maxdepth 1 -type f -name 'pulsedeck-agent-*.pkg.tar.*' ! -name '*.sig' -print
)
[[ ${#built_packages[@]} -eq 1 ]] \
    || fail "expected exactly one built pulsedeck-agent package, found ${#built_packages[@]}"

printf 'Installing package...\n'
sudo_run pacman -U --noconfirm "${built_packages[0]}"

[[ -x /usr/libexec/pulsedeck-agent/prepare-state.sh ]] \
    || fail "installed package is incomplete: prepare-state.sh is missing"
[[ -r /usr/lib/sysusers.d/pulsedeck-agent.conf ]] \
    || fail "installed package is incomplete: sysusers definition is missing"

sudo_run /usr/libexec/pulsedeck-agent/prepare-state.sh
sudo_run systemctl daemon-reload
sudo_run systemctl enable "$SERVICE" >/dev/null
sudo_run systemctl restart "$SERVICE"

if ! pulsedeck-agent doctor; then
    show_diagnostics
    printf '\nPulseDeck Agent installation failed its final health check.\n' >&2
    exit 6
fi

printf '\nPulseDeck Agent installation complete.\n'
pulsedeck-agent version
