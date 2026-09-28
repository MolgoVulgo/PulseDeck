#!/usr/bin/env bash
# PulseDeck master installer launcher — patch_0010-1
# Persistent entry point: refreshes installer scripts from GitHub, then runs setup_pi.sh.

set -u
set -o pipefail

REF="${PULSEDECK_REF:-main}"
REPO="${PULSEDECK_GITHUB_REPO:-MolgoVulgo/PulseDeck}"
INSTALL_PATH="${PULSEDECK_MASTER_PATH:-/usr/local/sbin/pulsedeck}"
SYSTEM_CACHE="${PULSEDECK_INSTALLER_CACHE:-/var/lib/pulsedeck/installer}"
CHECK_ONLY=0
OFFLINE=0
PASSTHRU=()
TEMP_DIR=""

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: pulsedeck [options passed to setup_pi.sh]

Master launcher behavior:
  1. fetch the current PulseDeck installer scripts from GitHub;
  2. validate their shell syntax;
  3. replace the cached copies only when content changed;
  4. update /usr/local/sbin/pulsedeck itself when needed;
  5. execute the refreshed setup_pi.sh.

Common options:
  --check              Validate without changing the PulseDeck system runtime.
  --hub-only           Update/check only pulsedeck-hub.
  --bootstrap-only     Update/check only the MQTT/system base.
  --verbose            Extra diagnostics.
  --non-interactive    Never prompt.
  --ref REF            Use another Git branch/tag.
  --offline            Skip GitHub refresh and use the cached scripts.
  --help               Show this help.

After the first installation, this command replaces repeated curl downloads of
setup_pi.sh. Internet access is only required when refreshing installer scripts
or when the selected deployment itself needs it.
EOF
}

while (($#)); do
  case "$1" in
    --check) CHECK_ONLY=1; PASSTHRU+=("$1"); shift ;;
    --offline) OFFLINE=1; shift ;;
    --ref)
      [[ $# -ge 2 ]] || { fail 'Missing value for --ref'; exit 64; }
      REF="$2"; PASSTHRU+=("--ref" "$2"); shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

if (( CHECK_ONLY == 0 )) && (( EUID != 0 )); then
  if command_exists sudo; then
    info 'Root privileges required; re-executing master launcher with sudo'
    sudo_args=("${PASSTHRU[@]}")
    (( OFFLINE )) && sudo_args+=(--offline)
    exec sudo env \
      PULSEDECK_REF="$REF" \
      PULSEDECK_GITHUB_REPO="$REPO" \
      PULSEDECK_INSTALLER_CACHE="$SYSTEM_CACHE" \
      bash "$0" "${sudo_args[@]}"
  fi
  fail 'Apply mode requires root and sudo is unavailable'
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

TEMP_DIR="$(mktemp -d)" || { fail 'mktemp failed'; exit 1; }
if (( CHECK_ONLY == 1 && OFFLINE == 0 )); then
  CACHE_DIR="${TEMP_DIR}/scripts"
elif (( EUID == 0 )); then
  CACHE_DIR="$SYSTEM_CACHE/scripts"
else
  CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/pulsedeck/installer/scripts"
fi
if (( CHECK_ONLY == 1 && OFFLINE == 1 )); then
  [[ -d "$CACHE_DIR" ]] || { fail "Offline installer cache is missing: $CACHE_DIR"; exit 1; }
else
  mkdir -p "$CACHE_DIR" || { fail "Cannot create installer cache: $CACHE_DIR"; exit 1; }
fi

scripts=(pulsedeck.sh setup_pi.sh bootstrap_pi.sh deploy_hub.sh)

if (( OFFLINE == 0 )); then
  info "Refreshing PulseDeck installer scripts from ${REPO}@${REF}"
  for name in "${scripts[@]}"; do
    url="https://raw.githubusercontent.com/${REPO}/${REF}/scripts/${name}"
    candidate="${TEMP_DIR}/${name}"
    if ! download_file "$url" "$candidate" || [[ ! -s "$candidate" ]]; then
      fail "Unable to download ${name}"
      exit 1
    fi
    if ! bash -n "$candidate"; then
      fail "Downloaded ${name} failed shell syntax validation"
      exit 1
    fi
  done

  for name in "${scripts[@]}"; do
    candidate="${TEMP_DIR}/${name}"
    cached="${CACHE_DIR}/${name}"
    if [[ -f "$cached" ]] && cmp -s "$candidate" "$cached"; then
      info "${name}: already current"
    else
      install -m 0755 "$candidate" "$cached" || { fail "Cannot update ${cached}"; exit 1; }
      ok "${name}: refreshed"
    fi
  done

  if (( EUID == 0 && CHECK_ONLY == 0 )); then
    remote_master="${CACHE_DIR}/pulsedeck.sh"
    if [[ ! -f "$INSTALL_PATH" ]] || ! cmp -s "$remote_master" "$INSTALL_PATH"; then
      install -d -m 0755 "$(dirname "$INSTALL_PATH")" || { fail "Cannot prepare $(dirname "$INSTALL_PATH")"; exit 1; }
      install -m 0755 "$remote_master" "$INSTALL_PATH" || { fail "Cannot install master launcher at ${INSTALL_PATH}"; exit 1; }
      ok "Master launcher installed/updated: ${INSTALL_PATH}"
      if [[ "${PULSEDECK_MASTER_REEXEC:-0}" != "1" ]]; then
        exec env PULSEDECK_MASTER_REEXEC=1 PULSEDECK_REF="$REF" PULSEDECK_GITHUB_REPO="$REPO" "$INSTALL_PATH" "${PASSTHRU[@]}"
      fi
    fi
  fi
else
  info "Offline mode: using cached installer scripts from ${CACHE_DIR}"
fi

for name in setup_pi.sh bootstrap_pi.sh deploy_hub.sh; do
  path="${CACHE_DIR}/${name}"
  [[ -s "$path" ]] || { fail "Cached installer script missing: ${path}"; exit 1; }
  bash -n "$path" || { fail "Cached installer script invalid: ${path}"; exit 1; }
done

exec env \
  PULSEDECK_REF="$REF" \
  PULSEDECK_GITHUB_REPO="$REPO" \
  PULSEDECK_MASTER=1 \
  bash "${CACHE_DIR}/setup_pi.sh" --source-dir "$CACHE_DIR" "${PASSTHRU[@]}"
