#!/usr/bin/env bash
# PulseDeck master installer launcher — git-004
# Stable channel follows immutable GitHub Releases; dev follows an immutable SHA resolved from branch dev.

set -u
set -o pipefail

REPO="${PULSEDECK_GITHUB_REPO:-MolgoVulgo/PulseDeck}"
INSTALL_PATH="${PULSEDECK_MASTER_PATH:-/usr/local/sbin/pulsedeck}"
SYSTEM_CACHE="${PULSEDECK_INSTALLER_CACHE:-/var/lib/pulsedeck/installer}"
METADATA_PATH="${SYSTEM_CACHE}/current.json"
DEV_BRANCH="${PULSEDECK_DEV_BRANCH:-dev}"
CHANNEL="${PULSEDECK_CHANNEL:-}"
LEGACY_ENV_REF="${PULSEDECK_REF:-}"
PINNED_COMMIT="${PULSEDECK_PINNED_COMMIT:-}"
RESOLVED_REF="${PULSEDECK_RESOLVED_REF:-}"
RESOLVED_COMMIT="${PULSEDECK_RESOLVED_COMMIT:-}"
EXPLICIT_REF=""
CHANNEL_EXPLICIT=0
CHECK_ONLY=0
OFFLINE=0
PASSTHRU=()
TEMP_DIR=""
ORIGINAL_ARGS=("$@")

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
  cat <<'USAGE'
Usage: pulsedeck [options passed to setup_pi.sh]

Update channels:
  stable  Default production channel. Resolves the latest stable GitHub Release,
          then pins every installer script to that release commit SHA.
  dev     Development channel. Resolves branch "dev" once, then pins every
          installer script to that exact commit SHA. No GitHub Release is used.

Common options:
  --channel stable|dev  Select the update channel.
  --check               Validate without changing the PulseDeck system runtime.
  --hub-only            Update/check only pulsedeck-hub.
  --bootstrap-only      Update/check only the MQTT/system base.
  --verbose             Extra diagnostics.
  --non-interactive     Never prompt.
  --offline             Skip GitHub resolution/refresh and use the selected
                        channel's cached scripts.
  --ref REF             Legacy/diagnostic override. REF is resolved once to a
                        commit SHA. "--ref dev" is treated as the dev channel.
  --help                Show this help.

Without --channel, PulseDeck reuses the installed stable/dev channel recorded
in /var/lib/pulsedeck/installer/current.json. If no metadata exists, stable is
used. The Git repository is not required on the Raspberry Pi.
USAGE
}

while (($#)); do
  case "$1" in
    --check) CHECK_ONLY=1; PASSTHRU+=("$1"); shift ;;
    --offline) OFFLINE=1; shift ;;
    --channel)
      [[ $# -ge 2 ]] || { fail 'Missing value for --channel'; exit 64; }
      case "$2" in stable|dev) CHANNEL="$2"; CHANNEL_EXPLICIT=1 ;; *) fail 'Channel must be stable or dev'; exit 64 ;; esac
      shift 2 ;;
    --ref)
      [[ $# -ge 2 ]] || { fail 'Missing value for --ref'; exit 64; }
      EXPLICIT_REF="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

if [[ -n "$EXPLICIT_REF" && "$CHANNEL_EXPLICIT" == "1" ]]; then
  fail '--ref and --channel cannot be combined'
  exit 64
fi

if (( CHECK_ONLY == 0 )) && (( EUID != 0 )); then
  if command_exists sudo; then
    info 'Root privileges required; re-executing master launcher with sudo'
    exec sudo env \
      PULSEDECK_GITHUB_REPO="$REPO" \
      PULSEDECK_INSTALLER_CACHE="$SYSTEM_CACHE" \
      PULSEDECK_DEV_BRANCH="$DEV_BRANCH" \
      bash "$0" "${ORIGINAL_ARGS[@]}"
  fi
  fail 'Apply mode requires root and sudo is unavailable'
  exit 1
fi

read_installed_channel() {
  [[ -r "$METADATA_PATH" ]] || return 1
  python - "$METADATA_PATH" <<'PY' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError, TypeError):
    raise SystemExit(1)
channel = data.get("channel")
if channel not in {"stable", "dev"}:
    raise SystemExit(1)
print(channel)
PY
}

if [[ -n "$EXPLICIT_REF" ]]; then
  if [[ "$EXPLICIT_REF" == "$DEV_BRANCH" ]]; then
    CHANNEL="dev"
  else
    CHANNEL="manual"
  fi
elif [[ -z "$CHANNEL" ]]; then
  if [[ -n "$LEGACY_ENV_REF" && "$LEGACY_ENV_REF" != "main" ]]; then
    EXPLICIT_REF="$LEGACY_ENV_REF"
    if [[ "$EXPLICIT_REF" == "$DEV_BRANCH" ]]; then CHANNEL="dev"; else CHANNEL="manual"; fi
  else
    CHANNEL="$(read_installed_channel || true)"
    [[ -n "$CHANNEL" ]] || CHANNEL="stable"
  fi
fi

case "$CHANNEL" in stable|dev|manual) ;; *) fail "Invalid resolved channel: $CHANNEL"; exit 64 ;; esac

if [[ "$CHANNEL" == "manual" && -z "$EXPLICIT_REF" ]]; then
  fail 'Manual channel requires --ref REF'
  exit 64
fi

resolve_target() {
  if [[ -n "$PINNED_COMMIT" ]]; then
    [[ "$PINNED_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || { fail 'Invalid pinned commit SHA'; return 1; }
    RESOLVED_COMMIT="${PINNED_COMMIT,,}"
    [[ -n "$RESOLVED_REF" ]] || RESOLVED_REF="$CHANNEL"
    return 0
  fi

  command_exists python || { fail 'Python is required to resolve GitHub refs'; return 1; }
  local output status
  output="$(python - "$REPO" "$CHANNEL" "$DEV_BRANCH" "$EXPLICIT_REF" <<'PY'
from __future__ import annotations
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

repo, channel, dev_branch, manual_ref = sys.argv[1:5]
if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
    raise SystemExit("invalid repository")
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "PulseDeck-Installer/git-004",
    "X-GitHub-Api-Version": "2022-11-28",
}

def get(path: str):
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/{path}", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"GitHub HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"GitHub unavailable: {exc.reason}") from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SystemExit("GitHub returned invalid JSON") from exc

def commit_for(ref: str) -> str:
    payload = get("commits/" + urllib.parse.quote(ref, safe=""))
    sha = payload.get("sha") if isinstance(payload, dict) else None
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
        raise SystemExit("GitHub returned an invalid commit SHA")
    return sha.lower()

if channel == "stable":
    release = get("releases/latest")
    tag = release.get("tag_name") if isinstance(release, dict) else None
    if not isinstance(tag, str) or not re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", tag):
        raise SystemExit("Latest GitHub Release has no valid stable tag")
    print(tag)
    print(commit_for(tag))
elif channel == "dev":
    print(dev_branch)
    print(commit_for(dev_branch))
elif channel == "manual":
    if not manual_ref:
        raise SystemExit("manual ref missing")
    print(manual_ref)
    print(commit_for(manual_ref))
else:
    raise SystemExit("unsupported channel")
PY
)"
  status=$?
  if (( status != 0 )); then
    fail "Unable to resolve ${CHANNEL} target"
    return 1
  fi
  RESOLVED_REF="$(sed -n '1p' <<<"$output")"
  RESOLVED_COMMIT="$(sed -n '2p' <<<"$output")"
  [[ -n "$RESOLVED_REF" && "$RESOLVED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
    fail 'GitHub target resolution returned invalid data'; return 1;
  }
}

load_offline_metadata() {
  [[ -r "$METADATA_PATH" ]] || return 1
  local output
  output="$(python - "$METADATA_PATH" "$CHANNEL" <<'PY' 2>/dev/null
import json,re,sys
try:
    data=json.load(open(sys.argv[1],encoding="utf-8"))
except (OSError,ValueError,TypeError):
    raise SystemExit(1)
if data.get("channel") != sys.argv[2]:
    raise SystemExit(1)
ref=data.get("resolved_ref") or data.get("branch") or data.get("tag_name") or data.get("channel")
commit=data.get("commit")
if not isinstance(ref,str) or not isinstance(commit,str) or not re.fullmatch(r"[0-9a-fA-F]{40}",commit):
    raise SystemExit(1)
print(ref); print(commit.lower())
PY
)" || return 1
  RESOLVED_REF="$(sed -n '1p' <<<"$output")"
  RESOLVED_COMMIT="$(sed -n '2p' <<<"$output")"
  return 0
}

if (( OFFLINE == 0 )); then
  resolve_target || exit 1
  info "Resolved PulseDeck channel ${CHANNEL}: ${RESOLVED_REF} -> ${RESOLVED_COMMIT:0:12}"
else
  if load_offline_metadata; then
    info "Offline mode: using recorded ${CHANNEL} target ${RESOLVED_COMMIT:0:12}"
  else
    warn "Offline mode: no matching installed commit metadata for channel ${CHANNEL}"
  fi
fi

TEMP_DIR="$(mktemp -d)" || { fail 'mktemp failed'; exit 1; }
if (( CHECK_ONLY == 1 && OFFLINE == 0 )); then
  CACHE_DIR="${TEMP_DIR}/scripts"
else
  CACHE_DIR="${SYSTEM_CACHE}/${CHANNEL}/scripts"
fi

if (( OFFLINE == 1 )); then
  if [[ ! -d "$CACHE_DIR" && -d "${SYSTEM_CACHE}/scripts" ]]; then
    warn "Using legacy installer cache: ${SYSTEM_CACHE}/scripts"
    CACHE_DIR="${SYSTEM_CACHE}/scripts"
  fi
  [[ -d "$CACHE_DIR" ]] || { fail "Offline installer cache is missing: $CACHE_DIR"; exit 1; }
else
  mkdir -p "$CACHE_DIR" || { fail "Cannot create installer cache: $CACHE_DIR"; exit 1; }
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
request = urllib.request.Request(url, headers={"User-Agent": "PulseDeck-Installer/git-004"})
with urllib.request.urlopen(request, timeout=15) as response, open(dest, "wb") as handle:
    handle.write(response.read())
PY
  else
    return 1
  fi
}

sync_deploy_payload_from_commit() {
  local archive source_root generator generated cached
  command_exists python || { fail 'Python is required to synchronize deploy payload'; return 1; }
  command_exists tar || { fail 'tar is required to synchronize deploy payload'; return 1; }

  archive="${TEMP_DIR}/source-${RESOLVED_COMMIT}.tar.gz"
  source_root="${TEMP_DIR}/source-${RESOLVED_COMMIT}"
  mkdir -p "$source_root" || return 1

  info "Verifying deployment payload against ${REPO}@${RESOLVED_COMMIT:0:12}"
  if ! download_file "https://codeload.github.com/${REPO}/tar.gz/${RESOLVED_COMMIT}" "$archive" || [[ ! -s "$archive" ]]; then
    fail "Unable to download source archive for deployment verification"
    return 1
  fi
  if ! tar -xzf "$archive" -C "$source_root" --strip-components=1; then
    fail "Unable to extract source archive for deployment verification"
    return 1
  fi

  generator="${source_root}/scripts/sync_deploy_payload.py"
  generated="${source_root}/scripts/deploy_hub.sh"
  cached="${CACHE_DIR}/deploy_hub.sh"
  [[ -s "$generator" && -s "$generated" ]] || {
    fail "Deployment synchronization files are missing from resolved commit"
    return 1
  }

  if python "$generator" --root "$source_root" --check >/dev/null 2>&1; then
    info "deploy_hub payload matches resolved commit sources"
  else
    warn "deploy_hub payload drift detected; rebuilding from resolved commit sources"
    python "$generator" --root "$source_root" --write || {
      fail "Unable to rebuild deploy_hub payload from resolved commit sources"
      return 1
    }
  fi

  python "$generator" --root "$source_root" --check || {
    fail "Rebuilt deploy_hub payload failed consistency verification"
    return 1
  }
  bash -n "$generated" || {
    fail "Rebuilt deploy_hub.sh failed shell syntax validation"
    return 1
  }

  if [[ -f "$cached" ]] && cmp -s "$generated" "$cached"; then
    info "deploy_hub.sh: synchronized payload already cached"
  else
    install -m 0755 "$generated" "$cached" || {
      fail "Cannot cache synchronized deploy_hub.sh"
      return 1
    }
    ok "deploy_hub.sh: payload synchronized from resolved commit sources"
  fi
}

scripts=(pulsedeck.sh setup_pi.sh bootstrap_pi.sh deploy_hub.sh)

if (( OFFLINE == 0 )); then
  info "Refreshing PulseDeck installer scripts from ${REPO}@${RESOLVED_COMMIT} (${CHANNEL})"
  for name in "${scripts[@]}"; do
    url="https://raw.githubusercontent.com/${REPO}/${RESOLVED_COMMIT}/scripts/${name}"
    candidate="${TEMP_DIR}/${name}"
    if ! download_file "$url" "$candidate" || [[ ! -s "$candidate" ]]; then
      fail "Unable to download ${name} from commit ${RESOLVED_COMMIT}"
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

  sync_deploy_payload_from_commit || exit 1

  if (( EUID == 0 && CHECK_ONLY == 0 )); then
    remote_master="${CACHE_DIR}/pulsedeck.sh"
    if [[ ! -f "$INSTALL_PATH" ]] || ! cmp -s "$remote_master" "$INSTALL_PATH"; then
      install -d -m 0755 "$(dirname "$INSTALL_PATH")" || { fail "Cannot prepare $(dirname "$INSTALL_PATH")"; exit 1; }
      install -m 0755 "$remote_master" "$INSTALL_PATH" || { fail "Cannot install master launcher at ${INSTALL_PATH}"; exit 1; }
      ok "Master launcher installed/updated: ${INSTALL_PATH}"
      if [[ "${PULSEDECK_MASTER_REEXEC:-0}" != "1" ]]; then
        exec env \
          PULSEDECK_MASTER_REEXEC=1 \
          PULSEDECK_CHANNEL="$CHANNEL" \
          PULSEDECK_GITHUB_REPO="$REPO" \
          PULSEDECK_INSTALLER_CACHE="$SYSTEM_CACHE" \
          PULSEDECK_DEV_BRANCH="$DEV_BRANCH" \
          PULSEDECK_PINNED_COMMIT="$RESOLVED_COMMIT" \
          PULSEDECK_RESOLVED_REF="$RESOLVED_REF" \
          PULSEDECK_RESOLVED_COMMIT="$RESOLVED_COMMIT" \
          "$INSTALL_PATH" "${ORIGINAL_ARGS[@]}"
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
  PULSEDECK_REF="${RESOLVED_COMMIT:-${RESOLVED_REF:-$CHANNEL}}" \
  PULSEDECK_GITHUB_REPO="$REPO" \
  PULSEDECK_MASTER=1 \
  PULSEDECK_CHANNEL="$CHANNEL" \
  PULSEDECK_DEV_BRANCH="$DEV_BRANCH" \
  PULSEDECK_RESOLVED_REF="$RESOLVED_REF" \
  PULSEDECK_RESOLVED_COMMIT="$RESOLVED_COMMIT" \
  bash "${CACHE_DIR}/setup_pi.sh" --source-dir "$CACHE_DIR" "${PASSTHRU[@]}"
