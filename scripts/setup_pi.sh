#!/usr/bin/env bash
# PulseDeck repository setup entry point — patch_0002-1
# Delegates host bootstrap work to the standalone script.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap_pi.sh"

if [[ ! -x "$BOOTSTRAP" ]]; then
    printf '[FAIL] Standalone bootstrap absent ou non exécutable: %s\n' "$BOOTSTRAP" >&2
    exit 1
fi

exec "$BOOTSTRAP" "$@"
