#!/usr/bin/env bash
# PulseDeck Raspberry Pi standalone bootstrap — patch_0002-1
# Self-contained: no PulseDeck repository checkout is required.

set -u
set -o pipefail

VERBOSE=0
CHECK_ONLY=0
APPLY_ALLOWED=1
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
LAN_IFACE=""
LAN_IPV4=""
LAN_CIDR=""
MOSQUITTO_INCLUDE_DIR=""

MOSQUITTO_MAIN_CONF="/etc/mosquitto/mosquitto.conf"
MOSQUITTO_DEFAULT_INCLUDE_DIR="/etc/mosquitto/conf.d"
MOSQUITTO_MANAGED_NAME="pulsedeck.conf"
MOSQUITTO_PERSIST_DIR="/var/lib/mosquitto"

usage() {
    cat <<'USAGE'
Usage: ./bootstrap_pi.sh [--check] [--verbose] [--help]

  --check     Run detection and validation only; make no changes.
  --verbose   Print additional detected values.
  --help      Show this help.

This script is standalone: it does not require a PulseDeck repository checkout.

Default mode installs/configures the PulseDeck MQTT base on the Raspberry Pi.
System changes require root, for example:

  sudo ./bootstrap_pi.sh

The script never runs pacman -Sy or pacman -Syu. Warnings do not stop later
checks. A failed step is reported and later independent checks continue.
USAGE
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

if (( CHECK_ONLY == 0 )) && (( EUID != 0 )); then
    warn "Mode application demandé sans privilèges root; aucune modification système ne sera effectuée"
    warn "Relancer avec sudo pour installer/configurer Mosquitto"
    APPLY_ALLOWED=0
fi

check_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
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

detect_network() {
    command_exists ip || { fail "Commande ip absente"; return 1; }

    local default_line global_v6
    default_line="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
    LAN_IFACE="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$default_line")"
    [[ -n "$LAN_IFACE" ]] || { fail "Aucune interface IPv4 portant une route par défaut"; return 1; }
    ok "Interface IPv4 par défaut: $LAN_IFACE"

    LAN_CIDR="$(ip -4 -o addr show dev "$LAN_IFACE" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
    if [[ -n "$LAN_CIDR" ]]; then
        LAN_IPV4="${LAN_CIDR%%/*}"
        ok "IPv4 LAN détectée: $LAN_CIDR"
    else
        fail "Aucune IPv4 globale sur $LAN_IFACE"
        return 1
    fi

    global_v6="$(ip -6 -o addr show scope global 2>/dev/null | head -n1 || true)"
    if [[ -z "$global_v6" ]]; then
        ok "Aucune IPv6 globale active (IPv6 non requis par PulseDeck V1)"
    else
        warn "IPv6 globale détectée alors que bluebox est prévu avec IPv6 désactivé"
        verbose "$global_v6"
    fi
}

check_port_1883_before_install() {
    command_exists ss || { warn "Commande ss absente; port 1883 non contrôlé"; return; }

    local listeners
    listeners="$(ss -lntH 2>/dev/null | awk '$4 ~ /:1883$/ {print $4}' || true)"
    if [[ -z "$listeners" ]]; then
        ok "Port TCP 1883 libre avant configuration"
    elif command_exists systemctl && systemctl is-active --quiet mosquitto 2>/dev/null; then
        ok "Port TCP 1883 déjà utilisé par un broker Mosquitto actif"
        verbose "${listeners//$'\n'/, }"
    else
        warn "Port TCP 1883 déjà en écoute avant démarrage Mosquitto: ${listeners//$'\n'/, }"
    fi
}

install_mosquitto() {
    if command_exists pacman && pacman -Q mosquitto >/dev/null 2>&1; then
        ok "Paquet mosquitto déjà installé"
        return 0
    fi

    if (( CHECK_ONLY )) || (( APPLY_ALLOWED == 0 )); then
        warn "Mosquitto non installé"
        return 1
    fi

    if ! command_exists pacman; then
        fail "pacman absent; installation Mosquitto impossible"
        return 1
    fi

    info "Installation de Mosquitto via pacman -S --needed (sans synchronisation ni upgrade global)"
    if pacman -S --needed --noconfirm mosquitto; then
        ok "Mosquitto installé"
    else
        fail "Installation Mosquitto échouée; aucune tentative pacman -Sy/-Syu n'est effectuée"
        return 1
    fi
}

active_mosquitto_include_dir() {
    [[ -r "$MOSQUITTO_MAIN_CONF" ]] || return 1
    awk '
        /^[[:space:]]*#/ {next}
        /^[[:space:]]*include_dir[[:space:]]+/ {print $2; exit}
    ' "$MOSQUITTO_MAIN_CONF"
}

ensure_mosquitto_include_dir() {
    [[ -f "$MOSQUITTO_MAIN_CONF" ]] || { fail "$MOSQUITTO_MAIN_CONF absent après installation"; return 1; }

    local include_dir backup
    include_dir="$(active_mosquitto_include_dir || true)"
    if [[ -n "$include_dir" ]]; then
        MOSQUITTO_INCLUDE_DIR="$include_dir"
        ok "Mosquitto include_dir existant: $MOSQUITTO_INCLUDE_DIR"
        return 0
    fi

    MOSQUITTO_INCLUDE_DIR="$MOSQUITTO_DEFAULT_INCLUDE_DIR"
    if (( CHECK_ONLY )) || (( APPLY_ALLOWED == 0 )); then
        warn "Aucun include_dir actif dans $MOSQUITTO_MAIN_CONF"
        return 0
    fi

    backup="${MOSQUITTO_MAIN_CONF}.pulsedeck-before-include"
    if [[ ! -e "$backup" ]]; then
        if cp -a "$MOSQUITTO_MAIN_CONF" "$backup"; then
            ok "Sauvegarde créée: $backup"
        else
            fail "Impossible de sauvegarder $MOSQUITTO_MAIN_CONF"
            return 1
        fi
    else
        ok "Sauvegarde Mosquitto déjà présente: $backup"
    fi

    mkdir -p "$MOSQUITTO_DEFAULT_INCLUDE_DIR" || { fail "Impossible de créer $MOSQUITTO_DEFAULT_INCLUDE_DIR"; return 1; }
    {
        printf '\n# PulseDeck managed include — bootstrap_pi.sh\n'
        printf 'include_dir %s\n' "$MOSQUITTO_DEFAULT_INCLUDE_DIR"
    } >> "$MOSQUITTO_MAIN_CONF" || { fail "Impossible d'ajouter include_dir à $MOSQUITTO_MAIN_CONF"; return 1; }

    ok "include_dir PulseDeck ajouté à $MOSQUITTO_MAIN_CONF"
    MOSQUITTO_INCLUDE_DIR="$MOSQUITTO_DEFAULT_INCLUDE_DIR"
}

check_listener_conflicts() {
    local include_dir="$1" managed_conf="$2" output=""
    local candidate

    for candidate in "$MOSQUITTO_MAIN_CONF" "$include_dir"/*.conf; do
        [[ -f "$candidate" ]] || continue
        [[ "$candidate" == "$managed_conf" ]] && continue
        while IFS= read -r line; do
            output+="$candidate:$line"$'\n'
        done < <(awk '
            /^[[:space:]]*#/ {next}
            /^[[:space:]]*listener[[:space:]]+1883([[:space:]]|$)/ {print NR ":" $0}
            /^[[:space:]]*port[[:space:]]+1883([[:space:]]|$)/ {print NR ":" $0}
        ' "$candidate")
    done

    if [[ -n "$output" ]]; then
        warn "Un listener/port MQTT 1883 existe déjà hors configuration PulseDeck; configuration automatique ignorée"
        verbose "$output"
        return 1
    fi
    return 0
}

render_mosquitto_config() {
    local include_dir="$1" managed_conf tmp
    managed_conf="$include_dir/$MOSQUITTO_MANAGED_NAME"

    [[ -n "$LAN_IPV4" ]] || { fail "IPv4 LAN inconnue; configuration MQTT impossible"; return 1; }

    if ! check_listener_conflicts "$include_dir" "$managed_conf"; then
        return 1
    fi

    if (( CHECK_ONLY )) || (( APPLY_ALLOWED == 0 )); then
        if [[ -r "$managed_conf" ]]; then
            if grep -q '^# Managed by PulseDeck bootstrap_pi.sh' "$managed_conf" && grep -q "^listener 1883 ${LAN_IPV4}$" "$managed_conf"; then
                ok "Configuration Mosquitto PulseDeck présente pour $LAN_IPV4:1883"
            else
                warn "Configuration Mosquitto PulseDeck présente mais différente de la cible"
            fi
        else
            warn "Configuration Mosquitto PulseDeck absente: $managed_conf"
        fi
        return 0
    fi

    mkdir -p "$include_dir" || { fail "Impossible de créer $include_dir"; return 1; }
    tmp="$(mktemp)" || { fail "mktemp impossible"; return 1; }

    cat >"$tmp" <<EOF
# Managed by PulseDeck bootstrap_pi.sh
# MQTT V1: LAN IPv4 only, anonymous, no ACL, no TLS.

listener 1883 ${LAN_IPV4}
listener_allow_anonymous true

persistence true
persistence_location ${MOSQUITTO_PERSIST_DIR}/
autosave_interval 1800
EOF

    if [[ -e "$managed_conf" ]] && \
       ! grep -q '^# Managed by PulseDeck bootstrap_pi.sh' "$managed_conf" && \
       ! grep -q '^# Managed by PulseDeck setup_pi.sh' "$managed_conf"; then
        warn "$managed_conf existe mais n'est pas identifié comme géré par PulseDeck; fichier conservé"
        rm -f "$tmp"
        return 1
    fi

    if [[ -e "$managed_conf" ]] && cmp -s "$tmp" "$managed_conf"; then
        ok "Configuration Mosquitto PulseDeck déjà à jour"
        rm -f "$tmp"
        return 0
    fi

    if install -m 0644 "$tmp" "$managed_conf"; then
        ok "Configuration Mosquitto écrite: $managed_conf"
        rm -f "$tmp"
    else
        rm -f "$tmp"
        fail "Impossible d'écrire $managed_conf"
        return 1
    fi
}

ensure_mosquitto_persistence_dir() {
    if [[ -d "$MOSQUITTO_PERSIST_DIR" ]]; then
        ok "Répertoire persistence Mosquitto présent: $MOSQUITTO_PERSIST_DIR"
        return 0
    fi

    if (( CHECK_ONLY )) || (( APPLY_ALLOWED == 0 )); then
        warn "Répertoire persistence Mosquitto absent: $MOSQUITTO_PERSIST_DIR"
        return 1
    fi

    if getent passwd mosquitto >/dev/null 2>&1 && getent group mosquitto >/dev/null 2>&1; then
        if install -d -m 0750 -o mosquitto -g mosquitto "$MOSQUITTO_PERSIST_DIR"; then
            ok "Répertoire persistence Mosquitto créé"
        else
            fail "Impossible de créer $MOSQUITTO_PERSIST_DIR"
            return 1
        fi
    else
        fail "Compte système mosquitto absent"
        return 1
    fi
}

validate_mosquitto_config() {
    command_exists mosquitto || { warn "Binaire mosquitto absent; configuration non validée"; return 1; }
    [[ -f "$MOSQUITTO_MAIN_CONF" ]] || { fail "$MOSQUITTO_MAIN_CONF absent"; return 1; }

    if mosquitto --help 2>&1 | grep -q -- '--test-config'; then
        if mosquitto --test-config -c "$MOSQUITTO_MAIN_CONF" >/dev/null 2>&1; then
            ok "Configuration Mosquitto valide (--test-config)"
        else
            fail "Configuration Mosquitto invalide"
            return 1
        fi
    else
        warn "Cette version de Mosquitto ne propose pas --test-config; validation statique limitée"
    fi
}

restart_mosquitto() {
    if (( CHECK_ONLY )) || (( APPLY_ALLOWED == 0 )); then
        if command_exists systemctl && systemctl is-active --quiet mosquitto 2>/dev/null; then
            ok "Service mosquitto actif"
        else
            warn "Service mosquitto inactif"
        fi
        return 0
    fi

    command_exists systemctl || { fail "systemctl absent; Mosquitto non démarré"; return 1; }

    if systemctl enable mosquitto >/dev/null 2>&1; then
        ok "Service mosquitto activé au boot"
    else
        fail "Impossible d'activer mosquitto au boot"
    fi

    if systemctl restart mosquitto; then
        ok "Service mosquitto démarré/redémarré"
    else
        fail "Échec du démarrage Mosquitto"
        return 1
    fi
}

check_listener_binding() {
    command_exists ss || { warn "Commande ss absente; bind MQTT non vérifié"; return 1; }
    [[ -n "$LAN_IPV4" ]] || { warn "IPv4 LAN inconnue; bind MQTT non vérifié"; return 1; }

    local listeners unexpected
    listeners="$(ss -lntH 2>/dev/null | awk '$4 ~ /:1883$/ {print $4}' || true)"
    if grep -Fxq "${LAN_IPV4}:1883" <<<"$listeners"; then
        ok "Mosquitto écoute sur ${LAN_IPV4}:1883"
    else
        warn "Listener attendu ${LAN_IPV4}:1883 non observé"
        verbose "Listeners 1883: ${listeners:-aucun}"
        return 1
    fi

    unexpected="$(grep -Ev "^${LAN_IPV4//./\\.}:1883$" <<<"$listeners" | sed '/^$/d' || true)"
    if [[ -n "$unexpected" ]]; then
        warn "Listener(s) MQTT supplémentaire(s) détecté(s): ${unexpected//$'\n'/, }"
    else
        ok "Aucun listener MQTT supplémentaire sur 1883"
    fi
}

mqtt_persistence_smoke_test() {
    if (( CHECK_ONLY )) || (( APPLY_ALLOWED == 0 )); then
        return 0
    fi

    local required=(mosquitto_pub mosquitto_sub timeout systemctl)
    local cmd
    for cmd in "${required[@]}"; do
        command_exists "$cmd" || { warn "$cmd absent; smoke test MQTT ignoré"; return 1; }
    done
    [[ -n "$LAN_IPV4" ]] || { warn "IPv4 LAN inconnue; smoke test MQTT ignoré"; return 1; }
    systemctl is-active --quiet mosquitto || { warn "Mosquitto inactif; smoke test ignoré"; return 1; }

    local topic token received
    topic="pulsedeck/v1/system/setup-test"
    token="pulsedeck-setup-$(date +%s)-$$"

    if ! mosquitto_pub -h "$LAN_IPV4" -p 1883 -q 1 -r -t "$topic" -m "$token"; then
        fail "Publication MQTT de test échouée"
        return 1
    fi
    ok "Publication MQTT QoS 1 retained réussie"

    if ! systemctl restart mosquitto; then
        fail "Redémarrage Mosquitto pendant le test de persistence échoué"
        return 1
    fi

    received="$(timeout 5s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t "$topic" -C 1 2>/dev/null || true)"
    if [[ "$received" == "$token" ]]; then
        ok "Retained restauré après redémarrage Mosquitto"
    else
        fail "Retained non restauré après redémarrage Mosquitto"
    fi

    if mosquitto_pub -h "$LAN_IPV4" -p 1883 -q 1 -r -n -t "$topic"; then
        ok "Topic de test MQTT nettoyé"
    else
        warn "Impossible de nettoyer le topic de test $topic"
    fi
}

print_summary() {
    printf '\n========================================\n'
    printf ' PulseDeck Raspberry Pi bootstrap\n'
    printf '========================================\n'
    [[ -n "$LAN_IFACE" ]] && printf 'LAN iface  %s\n' "$LAN_IFACE"
    [[ -n "$LAN_IPV4" ]] && printf 'LAN IPv4   %s\n' "$LAN_IPV4"
    printf 'Mode       %s\n' "$([[ "$CHECK_ONLY" == "1" || "$APPLY_ALLOWED" == "0" ]] && printf CHECK || printf APPLY)"
    printf 'OK         %d\n' "$OK_COUNT"
    printf 'Warnings   %d\n' "$WARN_COUNT"
    printf 'Failures   %d\n' "$FAIL_COUNT"
    if (( FAIL_COUNT > 0 )); then
        printf 'Status     COMPLETED WITH FAILURES\n'
    elif (( WARN_COUNT > 0 )); then
        printf 'Status     COMPLETE WITH WARNINGS\n'
    else
        printf 'Status     OK\n'
    fi
    printf '========================================\n'
}

info "PulseDeck standalone bootstrap patch_0002-1"
(( CHECK_ONLY )) && info "Mode --check: aucune modification système"

check_os
check_systemd
check_python
check_resources
detect_network || true
check_port_1883_before_install

if install_mosquitto; then
    if [[ -f "$MOSQUITTO_MAIN_CONF" ]]; then
        mqtt_config_ready=1
        mqtt_service_ready=0

        ensure_mosquitto_include_dir || mqtt_config_ready=0
        if [[ -n "$MOSQUITTO_INCLUDE_DIR" ]]; then
            render_mosquitto_config "$MOSQUITTO_INCLUDE_DIR" || mqtt_config_ready=0
        else
            fail "include_dir Mosquitto indéterminé"
            mqtt_config_ready=0
        fi
        ensure_mosquitto_persistence_dir || mqtt_config_ready=0
        validate_mosquitto_config || mqtt_config_ready=0

        if (( CHECK_ONLY )) || (( APPLY_ALLOWED == 0 )); then
            restart_mosquitto || true
            check_listener_binding || true
        elif (( mqtt_config_ready )); then
            if restart_mosquitto; then
                mqtt_service_ready=1
            fi
            check_listener_binding || true
            if (( mqtt_service_ready )); then
                mqtt_persistence_smoke_test || true
                check_listener_binding || true
            else
                warn "Smoke test MQTT ignoré car le service n'a pas démarré correctement"
            fi
        else
            warn "Configuration MQTT incomplète; redémarrage automatique de Mosquitto ignoré"
            check_listener_binding || true
        fi
    else
        fail "$MOSQUITTO_MAIN_CONF absent; configuration MQTT non appliquée"
    fi
fi

print_summary

(( FAIL_COUNT > 0 )) && exit 1
exit 0
