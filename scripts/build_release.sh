#!/usr/bin/env bash
# Build immutable PulseDeck stable-release assets from the current Git commit.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build_release.sh TAG [OUTPUT_DIR]

TAG must be a stable semantic version tag in the form vMAJOR.MINOR.PATCH.
The command writes three release assets:
  PulseDeck-TAG.tar.gz
  PulseDeck-TAG.tar.gz.sha256
  PulseDeck-TAG.json
EOF
}

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 64; }

TAG="$1"
OUT_DIR="${2:-dist}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${TAG#v}"
ARCHIVE="PulseDeck-${TAG}.tar.gz"
CHECKSUM="${ARCHIVE}.sha256"
METADATA="PulseDeck-${TAG}.json"

if [[ ! "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'Invalid stable release tag: %s (expected vMAJOR.MINOR.PATCH)\n' "$TAG" >&2
  exit 2
fi

command -v git >/dev/null 2>&1 || { printf 'git is required\n' >&2; exit 2; }
command -v python >/dev/null 2>&1 || { printf 'python is required\n' >&2; exit 2; }
command -v tar >/dev/null 2>&1 || { printf 'tar is required\n' >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { printf 'sha256sum is required\n' >&2; exit 2; }

cd "$ROOT"
python scripts/check_release_version.py --tag "$TAG"

if ! git rev-parse --verify --quiet "refs/tags/${TAG}^{commit}" >/dev/null; then
  printf 'Tag does not exist locally: %s\n' "$TAG" >&2
  exit 2
fi

TAG_COMMIT="$(git rev-list -n1 "$TAG")"
HEAD_COMMIT="$(git rev-parse HEAD)"
if [[ "$TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
  printf 'Refusing release: HEAD %s is not tag %s commit %s\n' "$HEAD_COMMIT" "$TAG" "$TAG_COMMIT" >&2
  exit 1
fi

release_scripts=(
  scripts/pulsedeck.sh
  scripts/setup_pi.sh
  scripts/bootstrap_pi.sh
  scripts/deploy_hub.sh
  scripts/install.sh
)

for path in "${release_scripts[@]}"; do
  [[ -s "$path" ]] || { printf 'Missing release file: %s\n' "$path" >&2; exit 1; }
  bash -n "$path"
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STAGE="${TMP_DIR}/PulseDeck-${TAG}"
mkdir -p "$STAGE/scripts"

for path in "${release_scripts[@]}"; do
  install -m 0755 "$path" "$STAGE/$path"
done

SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$TAG_COMMIT")"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$ARCHIVE" "$OUT_DIR/$CHECKSUM" "$OUT_DIR/$METADATA"

tar \
  --sort=name \
  --mtime="@${SOURCE_DATE_EPOCH}" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -czf "$OUT_DIR/$ARCHIVE" \
  -C "$TMP_DIR" "PulseDeck-${TAG}"

SHA256="$(sha256sum "$OUT_DIR/$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$ARCHIVE" > "$OUT_DIR/$CHECKSUM"

python - "$OUT_DIR/$METADATA" "$TAG" "$VERSION" "$TAG_COMMIT" "$ARCHIVE" "$SHA256" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = {
    "schema": 1,
    "project": "PulseDeck",
    "channel": "stable",
    "tag": sys.argv[2],
    "version": sys.argv[3],
    "commit": sys.argv[4],
    "artifact": sys.argv[5],
    "sha256": sys.argv[6],
    "entrypoint": "scripts/setup_pi.sh",
}
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

printf 'Release assets built in %s\n' "$OUT_DIR"
printf ' - %s\n - %s\n - %s\n' "$ARCHIVE" "$CHECKSUM" "$METADATA"
