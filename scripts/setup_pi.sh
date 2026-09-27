#!/usr/bin/env bash
# PulseDeck complete Raspberry Pi installer/orchestrator — patch_0006
# Works from a repository checkout or as a standalone script downloaded from GitHub.

set -u
set -o pipefail

CHECK_ONLY=0
VERBOSE=0
NON_INTERACTIVE=0
BOOTSTRAP_ONLY=0
HUB_ONLY=0
REF="${PULSEDECK_REF:-main}"
REPO="${PULSEDECK_GITHUB_REPO:-MolgoVulgo/PulseDeck}"
SOURCE_DIR=""
TEMP_DIR=""
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
RESOLVED_SCRIPT=""

ok()   { OK_COUNT=$((OK_COUNT + 1)); printf '[OK]   %s\n' "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
verbose() { (( VERBOSE )) && printf '[DEBUG] %s\n' "$*" || true; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

usage() {
    cat <<'USAGE'
Usage: ./setup_pi.sh [options]

Installation complète par défaut :
  1. bootstrap Raspberry Pi / Mosquitto
  2. déploiement ou mise à jour de pulsedeck-hub
  3. contrôles finaux des deux composants

Options :
  --check              Contrôler l'ensemble sans modifier le système.
  --verbose            Afficher davantage de diagnostics.
  --bootstrap-only     Installer/contrôler uniquement le socle MQTT.
  --hub-only           Installer/contrôler uniquement pulsedeck-hub.
  --non-interactive    Ne jamais poser de question ; échouer si une décision
                       manuelle est indispensable.
  --source-dir DIR     Utiliser bootstrap_pi.sh/deploy_hub.sh depuis DIR.
  --ref REF            Branche/tag GitHub à utiliser si un script doit être
                       téléchargé (défaut : main).
  --help               Afficher cette aide.

Le dépôt Git n'est pas requis sur le Raspberry Pi. Si les scripts spécialisés
ne sont pas présents à côté de setup_pi.sh, ils sont téléchargés depuis :
  https://github.com/MolgoVulgo/PulseDeck

Les questions interactives ne sont utilisées que lorsqu'une information ne
peut pas être déduite ou lorsqu'un script requis ne peut pas être récupéré
automatiquement.
USAGE
}

while (($#)); do
    case "$1" in
        --check) CHECK_ONLY=1 ; shift ;;
        --verbose) VERBOSE=1 ; shift ;;
        --non-interactive) NON_INTERACTIVE=1 ; shift ;;
        --bootstrap-only) BOOTSTRAP_ONLY=1 ; shift ;;
        --hub-only) HUB_ONLY=1 ; shift ;;
        --source-dir)
            [[ $# -ge 2 ]] || { printf 'Missing value for --source-dir\n' >&2; exit 64; }
            SOURCE_DIR="$2"; shift 2 ;;
        --ref)
            [[ $# -ge 2 ]] || { printf 'Missing value for --ref\n' >&2; exit 64; }
            REF="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    esac
done

if (( BOOTSTRAP_ONLY && HUB_ONLY )); then
    printf '[FAIL] --bootstrap-only et --hub-only sont incompatibles\n' >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "$SOURCE_DIR" ]] || SOURCE_DIR="$SCRIPT_DIR"

# Apply mode is privileged. Re-exec through sudo automatically when possible.
if (( CHECK_ONLY == 0 )) && (( EUID != 0 )); then
    if command_exists sudo; then
        info "Privilèges root nécessaires ; relance automatique via sudo"
        args=()
        (( VERBOSE )) && args+=(--verbose)
        (( NON_INTERACTIVE )) && args+=(--non-interactive)
        (( BOOTSTRAP_ONLY )) && args+=(--bootstrap-only)
        (( HUB_ONLY )) && args+=(--hub-only)
        [[ "$SOURCE_DIR" != "$SCRIPT_DIR" ]] && args+=(--source-dir "$SOURCE_DIR")
        [[ "$REF" != "main" ]] && args+=(--ref "$REF")
        exec sudo env PULSEDECK_REF="$REF" PULSEDECK_GITHUB_REPO="$REPO" bash "$0" "${args[@]}"
    fi
    fail "Installation complète nécessite root et sudo est absent"
    exit 1
fi

ask_path() {
    local script_name="$1" answer=""
    (( NON_INTERACTIVE )) && return 1
    [[ -t 0 ]] || return 1
    printf '[QUESTION] Chemin local vers %s (Entrée pour abandonner cette étape) : ' "$script_name" >&2
    IFS= read -r answer || return 1
    [[ -n "$answer" && -f "$answer" ]] || return 1
    printf '%s\n' "$answer"
}

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

resolve_script() {
    local name="$1" local_path raw_url downloaded manual
    RESOLVED_SCRIPT=""
    local_path="${SOURCE_DIR}/${name}"

    if [[ -f "$local_path" ]]; then
        if bash -n "$local_path"; then
            verbose "Script local sélectionné: $local_path"
            RESOLVED_SCRIPT="$local_path"
            return 0
        fi
        warn "Script local invalide: $local_path"
    fi

    [[ -n "$TEMP_DIR" ]] || TEMP_DIR="$(mktemp -d)" || { fail "mktemp impossible"; return 1; }
    downloaded="${TEMP_DIR}/${name}"
    raw_url="https://raw.githubusercontent.com/${REPO}/${REF}/scripts/${name}"
    info "${name} absent ou invalide localement ; récupération depuis GitHub (${REF})"

    if download_file "$raw_url" "$downloaded" && [[ -s "$downloaded" ]]; then
        if bash -n "$downloaded"; then
            chmod 0700 "$downloaded"
            ok "${name} récupéré et syntaxe validée"
            RESOLVED_SCRIPT="$downloaded"
            return 0
        fi
        warn "${name} téléchargé mais invalide ; fichier ignoré"
        rm -f "$downloaded"
    else
        warn "Téléchargement automatique de ${name} impossible"
        rm -f "$downloaded"
    fi

    manual="$(ask_path "$name" || true)"
    if [[ -n "$manual" ]] && bash -n "$manual"; then
        ok "${name} fourni manuellement et syntaxe validée"
        RESOLVED_SCRIPT="$manual"
        return 0
    fi

    fail "${name} indisponible ; étape impossible"
    return 1
}

run_component() {
    local label="$1" script="$2"
    shift 2
    local args=() log status child_warnings child_failures
    (( CHECK_ONLY )) && args+=(--check)
    (( VERBOSE )) && args+=(--verbose)

    [[ -n "$TEMP_DIR" ]] || TEMP_DIR="$(mktemp -d)" || { fail "mktemp impossible"; return 1; }
    log="${TEMP_DIR}/component-$RANDOM-$$.log"

    printf '\n========== %s ==========\n' "$label"
    if command_exists tee; then
        bash "$script" "${args[@]}" "$@" 2>&1 | tee "$log"
        status=${PIPESTATUS[0]}
    else
        bash "$script" "${args[@]}" "$@" >"$log" 2>&1
        status=$?
        cat "$log"
    fi

    child_warnings="$(awk '$1 == "Warnings" && $2 ~ /^[0-9]+$/ {value=$2} END {print value+0}' "$log" 2>/dev/null || printf '0')"
    child_failures="$(awk '$1 == "Failures" && $2 ~ /^[0-9]+$/ {value=$2} END {print value+0}' "$log" 2>/dev/null || printf '0')"
    [[ "$child_warnings" =~ ^[0-9]+$ ]] || child_warnings=0
    [[ "$child_failures" =~ ^[0-9]+$ ]] || child_failures=0

    WARN_COUNT=$((WARN_COUNT + child_warnings))
    FAIL_COUNT=$((FAIL_COUNT + child_failures))

    if (( child_warnings > 0 || child_failures > 0 )); then
        info "$label : ${child_warnings} warning(s), ${child_failures} failure(s) remonté(s)"
    fi

    if (( status == 0 && child_failures == 0 )); then
        ok "$label terminé"
        return 0
    fi

    if (( child_failures == 0 )); then
        fail "$label a signalé un échec sans compteur de failure exploitable"
    else
        info "$label a retourné un code d'échec ; failures déjà agrégées dans le résumé global"
    fi
    return 1
}

info "PulseDeck installation orchestrée"
info "Source GitHub: ${REPO}@${REF}"
(( CHECK_ONLY )) && info "Mode --check : aucune modification demandée aux sous-scripts"

BOOTSTRAP_SCRIPT=""
HUB_SCRIPT=""

if (( HUB_ONLY == 0 )); then
    if resolve_script bootstrap_pi.sh; then
        BOOTSTRAP_SCRIPT="$RESOLVED_SCRIPT"
        run_component "Bootstrap système / MQTT" "$BOOTSTRAP_SCRIPT" || true
    fi
fi

# The hub requires a working MQTT base. In full mode, don't hide a bootstrap failure.
if (( BOOTSTRAP_ONLY == 0 )); then
    if (( HUB_ONLY == 0 )) && (( FAIL_COUNT > 0 )); then
        warn "Déploiement du hub ignoré car le bootstrap système a échoué"
    else
        if resolve_script deploy_hub.sh; then
            HUB_SCRIPT="$RESOLVED_SCRIPT"
            run_component "Déploiement pulsedeck-hub" "$HUB_SCRIPT" || true
        fi
    fi
fi

printf '\n========================================\n'
printf ' PulseDeck complete setup\n'
printf '========================================\n'
printf 'Mode       %s\n' "$([[ "$CHECK_ONLY" == 1 ]] && printf CHECK || printf APPLY)"
printf 'Git ref    %s\n' "$REF"
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

(( FAIL_COUNT > 0 )) && exit 1
exit 0
