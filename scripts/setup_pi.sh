#!/usr/bin/env bash
# PulseDeck Raspberry Pi setup/preflight framework — patch_0001
# No system modification is performed by this revision.

set -u
set -o pipefail

VERBOSE=0
CHECK_ONLY=0
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

usage() {
    cat <<'EOF'
Usage: ./scripts/setup_pi.sh [--check] [--verbose] [--help]

  --check     Run preflight only. In patch_0001 this is equivalent to default mode.
  --verbose   Print additional detected values.
  --help      Show this help.

patch_0001 performs no package installation and no system modification.
EOF
}

ok()   { OK_COUNT=$((OK_COUNT + 1)); printf '[OK]   %s\n' "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
verbose() { if (( VERBOSE )); then printf '[DEBUG] %s\n' "$*"; fi; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --verbose) VERBOSE=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 64 ;;
    esac
done

check_os() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID:-}" == "archarm" ]]; then
            ok "OS: ${PRETTY_NAME:-Arch Linux ARM}"
        else
            warn "OS détecté: ${PRETTY_NAME:-unknown}; la plateforme de référence est Arch Linux ARM"
        fi
    else
        fail "/etc/os-release illisible"
    fi

    local arch kernel
    arch="$(uname -m 2>/dev/null || true)"
    if [[ "$arch" == "armv7l" ]]; then
        ok "Architecture: armv7l"
    elif [[ -n "$arch" ]]; then
        warn "Architecture détectée: $arch; plateforme de référence: armv7l"
    else
        fail "Architecture impossible à déterminer"
    fi

    kernel="$(uname -r 2>/dev/null || true)"
    [[ -n "$kernel" ]] && ok "Kernel: $kernel" || fail "Kernel impossible à déterminer"
}

check_systemd() {
    command_exists systemctl && ok "systemd/systemctl disponible" || fail "systemctl absent"
}

check_python() {
    if ! command_exists python; then
        warn "Python absent"
        return
    fi

    local pyver
    pyver="$(python -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || true)"
    [[ -n "$pyver" ]] && ok "Python: $pyver" || { fail "Python présent mais version illisible"; return; }

    if python -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,14) else 1)' >/dev/null 2>&1; then
        ok "Python >= 3.14"
    else
        warn "Python < 3.14; runtime de référence observé: Python 3.14.5"
    fi
}

check_resources() {
    if command_exists free; then
        local mem
        mem="$(free -h 2>/dev/null | awk '/^Mem:/ {print $2 " total, " $7 " available"}')"
        [[ -n "$mem" ]] && ok "Mémoire: $mem" || warn "Mémoire non déterminée"
    else
        warn "Commande free absente"
    fi

    if [[ -r /proc/swaps ]]; then
        local swap_lines
        swap_lines="$(tail -n +2 /proc/swaps 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$swap_lines" == "0" ]] && warn "Aucun swap configuré; accepté pour la V1 tant que la mémoire reste suffisante" || ok "Swap configuré"
    fi

    local avail_kb
    avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
        (( avail_kb >= 2 * 1024 * 1024 )) && ok "Espace libre sur /: $((avail_kb / 1024)) MiB" || warn "Espace libre faible sur /: $((avail_kb / 1024)) MiB"
    else
        warn "Espace disque non déterminé"
    fi
}

check_network() {
    command_exists ip || { fail "Commande ip absente"; return; }

    local default_line iface ipv4 global_v6
    default_line="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
    iface="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$default_line")"
    [[ -n "$iface" ]] || { fail "Aucune interface IPv4 portant une route par défaut"; return; }
    ok "Interface IPv4 par défaut: $iface"

    ipv4="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
    [[ -n "$ipv4" ]] && ok "IPv4 LAN détectée: $ipv4" || fail "Aucune IPv4 globale sur $iface"

    global_v6="$(ip -6 -o addr show scope global 2>/dev/null | head -n1 || true)"
    if [[ -z "$global_v6" ]]; then
        ok "Aucune IPv6 globale active (IPv6 non requis par PulseDeck V1)"
    else
        warn "IPv6 globale détectée alors que bluebox est prévu avec IPv6 désactivé"
        verbose "$global_v6"
    fi
}

check_mqtt() {
    if command_exists pacman && pacman -Q mosquitto >/dev/null 2>&1; then
        ok "Paquet mosquitto installé"
    else
        warn "Mosquitto non installé"
    fi

    if command_exists ss; then
        local listeners
        listeners="$(ss -lnt 2>/dev/null | awk '$4 ~ /:1883$/ {print $4}' || true)"
        [[ -z "$listeners" ]] && ok "Port TCP 1883 libre" || warn "Port TCP 1883 déjà en écoute: ${listeners//$'\n'/, }"
    else
        warn "Commande ss absente; port 1883 non contrôlé"
    fi
}

print_summary() {
    printf '\n========================================\n'
    printf ' PulseDeck Raspberry Pi preflight\n'
    printf '========================================\n'
    printf 'OK       %d\n' "$OK_COUNT"
    printf 'Warnings %d\n' "$WARN_COUNT"
    printf 'Failures %d\n' "$FAIL_COUNT"
    if (( FAIL_COUNT > 0 )); then
        printf 'Status   COMPLETED WITH FAILURES\n'
    elif (( WARN_COUNT > 0 )); then
        printf 'Status   COMPLETE WITH WARNINGS\n'
    else
        printf 'Status   OK\n'
    fi
    printf '========================================\n'
}

info "PulseDeck setup framework patch_0001"
(( CHECK_ONLY == 0 )) && info "Aucune modification système dans cette révision; exécution du préflight uniquement"

check_os
check_systemd
check_python
check_resources
check_network
check_mqtt
print_summary

(( FAIL_COUNT > 0 )) && exit 1
exit 0
