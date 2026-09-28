#!/usr/bin/env bash
# PulseDeck first-install bootstrap — patch_0011
# Installs the persistent `pulsedeck` master launcher, then delegates everything to it.

set -u
set -o pipefail

REF="${PULSEDECK_REF:-main}"
REPO="${PULSEDECK_GITHUB_REPO:-MolgoVulgo/PulseDeck}"
MASTER_PATH="${PULSEDECK_MASTER_PATH:-/usr/local/sbin/pulsedeck}"
SYSTEM_CACHE="${PULSEDECK_INSTALLER_CACHE:-/var/lib/pulsedeck/installer}"
RUN_AFTER_INSTALL=1
PASSTHRU=()
TEMP_DIR=""

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage:
  curl -fsSL https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/install.sh | sudo bash

Optional arguments when running a downloaded copy or via `bash -s --`:
  --ref REF            Git branch/tag/commit used for the initial master download.
  --install-only       Install /usr/local/sbin/pulsedeck but do not start deployment.
  --help               Show this help.

All other arguments are forwarded to the persistent `pulsedeck` command.
Examples:
  curl -fsSL URL | sudo bash -s -- --check
  curl -fsSL URL | sudo bash -s -- --ref main --hub-only

The bootstrap downloads only scripts/pulsedeck.sh. The installed master launcher
then refreshes setup_pi.sh, bootstrap_pi.sh and deploy_hub.sh as needed.
USAGE
}

while (($#)); do
  case "$1" in
    --ref)
      [[ $# -ge 2 ]] || { fail 'Missing value for --ref'; exit 64; }
      REF="$2"
      PASSTHRU+=("--ref" "$2")
      shift 2
      ;;
    --install-only)
      RUN_AFTER_INSTALL=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      PASSTHRU+=("$1")
      shift
      ;;
  esac
done

if (( EUID != 0 )); then
  fail 'First installation requires root. Use: curl -fsSL <install.sh URL> | sudo bash'
  exit 1
fi

download_file() {
  local url="$1" dest="$2"
  if command_exists curl; then
    curl -fsSL --retry 2 --connect-timeout 10 "$url" -o "$dest"
  elif command_exists wget; then
    wget -qO "$dest" "$url"
  elif command_exists python; then
    python - "$url" "$dest" <<'PY'
import sys
import urllib.request
url, dest = sys.argv[1:3]
with urllib.request.urlopen(url, timeout=15) as response, open(dest, "wb") as handle:
    handle.write(response.read())
PY
  else
    return 1
  fi
}

for cmd in bash install mktemp; do
  command_exists "$cmd" || { fail "Required command missing: $cmd"; exit 1; }
done

TEMP_DIR="$(mktemp -d)" || { fail 'mktemp failed'; exit 1; }
MASTER_CANDIDATE="${TEMP_DIR}/pulsedeck.sh"
MASTER_URL="https://raw.githubusercontent.com/${REPO}/${REF}/scripts/pulsedeck.sh"

info "Installing PulseDeck master launcher from ${REPO}@${REF}"
if ! download_file "$MASTER_URL" "$MASTER_CANDIDATE" || [[ ! -s "$MASTER_CANDIDATE" ]]; then
  fail 'Unable to download scripts/pulsedeck.sh'
  exit 1
fi
if ! bash -n "$MASTER_CANDIDATE"; then
  fail 'Downloaded master launcher failed shell syntax validation'
  exit 1
fi

install -d -m 0755 "$(dirname "$MASTER_PATH")" || { fail "Cannot prepare $(dirname "$MASTER_PATH")"; exit 1; }
install -d -m 0755 "${SYSTEM_CACHE}/scripts" || { fail "Cannot prepare ${SYSTEM_CACHE}/scripts"; exit 1; }
install -m 0755 "$MASTER_CANDIDATE" "${SYSTEM_CACHE}/scripts/pulsedeck.sh" || { fail 'Cannot seed installer cache'; exit 1; }
install -m 0755 "$MASTER_CANDIDATE" "$MASTER_PATH" || { fail "Cannot install ${MASTER_PATH}"; exit 1; }
ok "Master launcher installed: ${MASTER_PATH}"

if (( RUN_AFTER_INSTALL == 0 )); then
  info "Installation complete. Run: sudo pulsedeck"
  exit 0
fi

info 'Starting PulseDeck installation through the persistent master launcher'
exec env \
  PULSEDECK_REF="$REF" \
  PULSEDECK_GITHUB_REPO="$REPO" \
  PULSEDECK_INSTALLER_CACHE="$SYSTEM_CACHE" \
  "$MASTER_PATH" "${PASSTHRU[@]}"
