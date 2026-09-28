#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — git-006
# Self-contained: no PulseDeck repository checkout is required.

set -u
set -o pipefail

CHECK_ONLY=0
VERBOSE=0
NON_INTERACTIVE=0
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
LAN_IFACE=""
LAN_IPV4=""

APP_ROOT="/opt/pulsedeck"
APP_DIR="${APP_ROOT}/hub"
VENV_DIR="${APP_ROOT}/venv"
CONFIG_DIR="/etc/pulsedeck"
CONFIG_FILE="${CONFIG_DIR}/pulsedeck.toml"
SECRET_DIR="${CONFIG_DIR}/secrets"
WEATHER_KEY_FILE="${SECRET_DIR}/openweather_api_key"
NEWSAPI_KEY_FILE="${SECRET_DIR}/newsapi_api_key"
GNEWS_KEY_FILE="${SECRET_DIR}/gnews_api_key"
STATE_DIR="/var/lib/pulsedeck"
INSTALL_METADATA_PATH="${STATE_DIR}/installer/current.json"
REPO="${PULSEDECK_GITHUB_REPO:-MolgoVulgo/PulseDeck}"
ADMIN_STATE_DIR="${STATE_DIR}/admin"
ADMIN_PASSWORD_HASH="${ADMIN_STATE_DIR}/password.hash"
ADMIN_SESSION_KEY="${ADMIN_STATE_DIR}/session.key"
UNIT_FILE="/etc/systemd/system/pulsedeck-hub.service"
SERVICE="pulsedeck-hub.service"
RUN_USER="pulsedeck"
RUN_GROUP="pulsedeck"
ADMIN_PORT=8080
MASTER_PATH="/usr/local/sbin/pulsedeck"
UPDATER_ROOT="/var/lib/pulsedeck-updater"
UPDATER_INBOX="${UPDATER_ROOT}/inbox"
UPDATER_STATUS_DIR="${UPDATER_ROOT}/status"
UPDATER_WORKER="/usr/local/libexec/pulsedeck-updater"
UPDATER_UNIT_FILE="/etc/systemd/system/pulsedeck-updater.service"
UPDATER_PATH_FILE="/etc/systemd/system/pulsedeck-updater.path"
UPDATER_PATH_SERVICE="pulsedeck-updater.path"

ok() { OK_COUNT=$((OK_COUNT+1)); printf '[OK]   %s\n' "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT+1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); printf '[KO]   %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
verbose() { (( VERBOSE )) && printf '[DEBUG] %s\n' "$*" || true; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: ./deploy_hub.sh [--check] [--verbose] [--non-interactive] [--help]

  --check            Validate host/runtime state without changing anything.
  --verbose          Print extra diagnostic values.
  --non-interactive  Compatibility flag; Web Admin owns service configuration.
  --help             Show this help.

Default mode installs/updates the PulseDeck Hub into /opt/pulsedeck,
activates the LAN-only Web Admin, preserves existing collector settings and
never asks for service/API configuration. No Git checkout is required.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --verbose) VERBOSE=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 64 ;;
  esac
done

if (( CHECK_ONLY == 0 )) && (( EUID != 0 )); then
  fail "Mode application nécessite root; relancer avec sudo"
  CHECK_ONLY=1
fi

write_install_metadata() {
  local channel="${PULSEDECK_CHANNEL:-}" resolved_ref="${PULSEDECK_RESOLVED_REF:-}" commit="${PULSEDECK_RESOLVED_COMMIT:-}"
  local branch="${PULSEDECK_DEV_BRANCH:-dev}" version
  if [[ -z "$channel" ]]; then
    warn "Métadonnées de canal absentes; état d'installation existant conservé"
    return 0
  fi
  case "$channel" in stable|dev|manual) ;; *) fail "Canal d'installation invalide: $channel"; return 1 ;; esac
  if [[ -n "$commit" && ! "$commit" =~ ^[0-9a-fA-F]{40}$ ]]; then
    fail "Commit d'installation invalide"
    return 1
  fi
  if [[ "$channel" == "dev" && -z "$commit" ]]; then
    fail "Commit dev absent; métadonnées d'installation non écrites"
    return 1
  fi
  version="$($VENV_DIR/bin/python -c 'from pulsedeck_hub import __version__; print(__version__)' 2>/dev/null || true)"
  [[ -n "$version" ]] || { fail "Version installée impossible à déterminer"; return 1; }
  install -d -m 0755 -o root -g "$RUN_GROUP" "$(dirname "$INSTALL_METADATA_PATH")" || {
    fail "Création du répertoire de métadonnées impossible"; return 1;
  }
  "$VENV_DIR/bin/python" - "$INSTALL_METADATA_PATH" "$channel" "$REPO" "$resolved_ref" "$commit" "$branch" "$version" <<'PYMETA'
from __future__ import annotations
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
channel, repository, resolved_ref, commit, branch, version = sys.argv[2:8]
data = {
    "schema": 1,
    "repository": repository,
    "channel": channel,
    "version": version,
    "resolved_ref": resolved_ref or None,
    "commit": commit.lower() or None,
    "branch": branch if channel == "dev" else None,
    "tag_name": resolved_ref if channel == "stable" and resolved_ref.startswith("v") else None,
    "installed_at": datetime.now(timezone.utc).isoformat(),
}
tmp = path.with_name(path.name + ".tmp")
tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.replace(tmp, path)
PYMETA
  if [[ $? -ne 0 ]]; then
    fail "Écriture des métadonnées d'installation échouée"
    return 1
  fi
  chown root:"$RUN_GROUP" "$INSTALL_METADATA_PATH" || return 1
  chmod 0640 "$INSTALL_METADATA_PATH" || return 1
  ok "Canal installé: ${channel}${commit:+ / ${commit:0:12}}"
}

install_master_launcher() {
  local source="$1"
  if [[ ! -s "$source" ]] || ! bash -n "$source"; then
    warn "Master launcher not installed: embedded script is missing or invalid"
    return 0
  fi
  if [[ -f "$MASTER_PATH" ]] && cmp -s "$source" "$MASTER_PATH"; then
    ok "Master launcher current: ${MASTER_PATH}"
    return 0
  fi
  install -d -m 0755 "$(dirname "$MASTER_PATH")" || { warn "Master launcher directory preparation failed"; return 0; }
  if install -m 0755 "$source" "$MASTER_PATH"; then
    ok "Master launcher installed/updated: ${MASTER_PATH}"
  else
    warn "Master launcher installation failed: ${MASTER_PATH}"
  fi
}

install_privileged_updater() {
  local tmp="$1" target source
  source="$tmp/pulsedeck-updater.sh"
  if [[ ! -s "$source" ]] || ! bash -n "$source"; then
    fail "Worker updater privilégié absent ou invalide"
    return 1
  fi

  install -d -m 0755 -o root -g root "$UPDATER_ROOT" || { fail "Création $UPDATER_ROOT échouée"; return 1; }
  install -d -m 0770 -o root -g "$RUN_GROUP" "$UPDATER_INBOX" || { fail "Création inbox updater échouée"; return 1; }
  install -d -m 0750 -o root -g "$RUN_GROUP" "$UPDATER_STATUS_DIR" || { fail "Création status updater échouée"; return 1; }
  install -d -m 0755 -o root -g root "$(dirname "$UPDATER_WORKER")" || { fail "Création libexec échouée"; return 1; }
  install -m 0755 -o root -g root "$source" "$UPDATER_WORKER" || { fail "Installation worker updater échouée"; return 1; }

  for target in "$UPDATER_UNIT_FILE" "$UPDATER_PATH_FILE"; do
    if [[ -e "$target" ]] && ! grep -q '^# Managed by PulseDeck deploy_hub.sh' "$target"; then
      fail "$target existe sans marqueur PulseDeck; remplacement refusé"
      return 1
    fi
  done
  install -m 0644 -o root -g root "$tmp/pulsedeck-updater.service" "$UPDATER_UNIT_FILE" || { fail "Installation unité updater échouée"; return 1; }
  install -m 0644 -o root -g root "$tmp/pulsedeck-updater.path" "$UPDATER_PATH_FILE" || { fail "Installation path updater échouée"; return 1; }
  ok "Updater privilégié séparé installé"
}

detect_network() {
  command_exists ip || { fail "Commande ip absente"; return 1; }
  local line
  line="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
  LAN_IFACE="$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}' <<<"$line")"
  [[ -n "$LAN_IFACE" ]] || { fail "Aucune interface IPv4 par défaut"; return 1; }
  LAN_IPV4="$(ip -4 -o addr show dev "$LAN_IFACE" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
  [[ -n "$LAN_IPV4" ]] || { fail "Aucune IPv4 globale sur $LAN_IFACE"; return 1; }
  ok "IPv4 LAN: $LAN_IPV4 via $LAN_IFACE"
}

check_prereqs() {
  local cmd
  for cmd in python systemctl tar base64 install timeout getent cmp sleep runuser; do
    command_exists "$cmd" || fail "Commande requise absente: $cmd"
  done
  if command_exists python; then
    local version
    version="$(python -c 'import sys;print(".".join(map(str,sys.version_info[:3])))' 2>/dev/null || true)"
    if python -c 'import sys;raise SystemExit(0 if sys.version_info >= (3,14) else 1)' >/dev/null 2>&1; then
      ok "Python: $version"
    else
      fail "Python >= 3.14 requis; détecté: ${version:-unknown}"
    fi
  fi
  if systemctl is-active --quiet mosquitto 2>/dev/null; then
    ok "Mosquitto actif"
  else
    fail "Mosquitto n'est pas actif; exécuter bootstrap_pi.sh avant le hub"
  fi
}

ensure_user() {
  if id "$RUN_USER" >/dev/null 2>&1; then
    ok "Utilisateur système $RUN_USER présent"
    return 0
  fi
  command_exists useradd || { fail "useradd absent; utilisateur $RUN_USER non créé"; return 1; }
  command_exists groupadd || { fail "groupadd absent; groupe $RUN_GROUP non créé"; return 1; }
  if ! getent group "$RUN_GROUP" >/dev/null 2>&1; then
    groupadd --system "$RUN_GROUP" || { fail "Création groupe $RUN_GROUP échouée"; return 1; }
    ok "Groupe système $RUN_GROUP créé"
  fi
  if useradd --system --gid "$RUN_GROUP" --home-dir "$STATE_DIR" --create-home --shell /usr/bin/nologin "$RUN_USER"; then
    ok "Utilisateur système $RUN_USER créé"
  else
    fail "Création utilisateur $RUN_USER échouée"
    return 1
  fi
}

extract_payload() {
  local target="$1"
  mkdir -p "$target" || return 1
  sed -n '/^__PULSEDECK_PAYLOAD__$/,$p' "$0" | tail -n +2 | base64 -d | tar -xzf - -C "$target"
}

configure_admin_block() {
  python - "$CONFIG_FILE" "$LAN_IPV4" <<'PY'
import re,sys
from pathlib import Path
path=Path(sys.argv[1]); ip=sys.argv[2]
text=path.read_text(encoding='utf-8')
block=f'[admin]\nenabled = true\nlisten = "{ip}"\nport = 8080\n'
pattern=re.compile(r'(?ms)^\[admin\]\n.*?(?=^\[|\Z)')
if pattern.search(text): text=pattern.sub(block+'\n',text,count=1)
else: text=text.rstrip()+'\n\n'+block
path.write_text(text,encoding='utf-8')
PY
  python -c 'import sys,tomllib;tomllib.load(open(sys.argv[1],"rb"))' "$CONFIG_FILE" || {
    fail "Configuration TOML invalide après activation Web Admin"; return 1;
  }
  ok "Web Admin activé sur ${LAN_IPV4}:${ADMIN_PORT}"
}

prepare_config_permissions() {
  install -d -m 0770 -o root -g "$RUN_GROUP" "$CONFIG_DIR" "$SECRET_DIR" || {
    fail "Permissions runtime /etc/pulsedeck impossibles"; return 1;
  }
  chown root:"$RUN_GROUP" "$CONFIG_FILE" || return 1
  chmod 0660 "$CONFIG_FILE" || return 1
  if [[ -e "$WEATHER_KEY_FILE" ]]; then
    chown root:"$RUN_GROUP" "$WEATHER_KEY_FILE" || return 1
    chmod 0660 "$WEATHER_KEY_FILE" || return 1
  fi
  if [[ -e "$NEWSAPI_KEY_FILE" ]]; then
    chown root:"$RUN_GROUP" "$NEWSAPI_KEY_FILE" || return 1
    chmod 0660 "$NEWSAPI_KEY_FILE" || return 1
  fi
  if [[ -e "$GNEWS_KEY_FILE" ]]; then
    chown root:"$RUN_GROUP" "$GNEWS_KEY_FILE" || return 1
    chmod 0660 "$GNEWS_KEY_FILE" || return 1
  fi
  ok "Configuration Web modifiable par le service pulsedeck"
}

ensure_admin_credentials() {
  install -d -m 0700 -o "$RUN_USER" -g "$RUN_GROUP" "$ADMIN_STATE_DIR" || {
    fail "Création état Web Admin échouée"; return 1;
  }
  if [[ ! -s "$ADMIN_SESSION_KEY" ]]; then
    "$VENV_DIR/bin/python" - "$ADMIN_SESSION_KEY" <<'PY'
import os,secrets,sys
p=sys.argv[1]
fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'wb') as f:f.write(secrets.token_bytes(32))
PY
    chown "$RUN_USER":"$RUN_GROUP" "$ADMIN_SESSION_KEY" || true
    chmod 0600 "$ADMIN_SESSION_KEY" || true
  fi
  if [[ -s "$ADMIN_PASSWORD_HASH" ]]; then
    chown "$RUN_USER":"$RUN_GROUP" "$ADMIN_PASSWORD_HASH" || true
    chmod 0600 "$ADMIN_PASSWORD_HASH" || true
    ok "Identifiants Web Admin existants conservés"
    return 0
  fi
  local generated password encoded
  generated="$("$VENV_DIR/bin/python" - <<'PY'
from pulsedeck_hub.admin.security import generate_password,hash_password
p=generate_password(); print(p); print(hash_password(p))
PY
)" || { fail "Génération identifiants Web Admin échouée"; return 1; }
  password="$(sed -n '1p' <<<"$generated")"
  encoded="$(sed -n '2p' <<<"$generated")"
  printf '%s\n' "$encoded" > "$ADMIN_PASSWORD_HASH"
  chown "$RUN_USER":"$RUN_GROUP" "$ADMIN_PASSWORD_HASH"
  chmod 0600 "$ADMIN_PASSWORD_HASH"
  ok "Identifiants Web Admin générés"
  printf '\n[IMPORTANT] PulseDeck Admin: http://%s:%s\n' "$LAN_IPV4" "$ADMIN_PORT"
  printf '[IMPORTANT] Utilisateur: admin\n'
  printf '[IMPORTANT] Mot de passe initial: %s\n\n' "$password"
}

weather_enabled() {
  [[ -r "$CONFIG_FILE" ]] || return 1
  python - "$CONFIG_FILE" <<'PY' >/dev/null 2>&1
import sys,tomllib
with open(sys.argv[1],'rb') as f:c=tomllib.load(f)
raise SystemExit(0 if c.get('collectors',{}).get('weather',{}).get('enabled') is True else 1)
PY
}

weather_api_smoke_test() {
  if ! weather_enabled; then
    info "Weather désactivé; configuration disponible dans Web Admin"
    return 0
  fi
  if [[ ! -s "$WEATHER_KEY_FILE" ]]; then
    warn "Weather activé mais clé OpenWeather absente"
    return 0
  fi
  local result
  result="$("$VENV_DIR/bin/python" - "$CONFIG_FILE" <<'PY'
import sys
from pulsedeck_hub.collectors.weather import OpenWeatherClient
from pulsedeck_hub.config import load_config
cfg=load_config(__import__('pathlib').Path(sys.argv[1])).weather
client=OpenWeatherClient(cfg)
current=client.current(); hourly=client.timeline('1h',cfg.hourly_hours)
if not current.data or len(hourly.data)!=cfg.hourly_hours: raise SystemExit(1)
print(f"{current.timezone} / {current.data[0].get('temp','?')} C / hourly {len(hourly.data)} records")
PY
)" || { warn "Validation OpenWeather existante échouée; Web Admin permettra de corriger la configuration"; return 0; }
  ok "OpenWeather One Call 4.0 répond: $result"
}


news_enabled() {
  [[ -r "$CONFIG_FILE" ]] || return 1
  python - "$CONFIG_FILE" <<'PY' >/dev/null 2>&1
import sys,tomllib
with open(sys.argv[1],'rb') as f:c=tomllib.load(f)
raise SystemExit(0 if c.get('collectors',{}).get('news',{}).get('enabled') is True else 1)
PY
}

news_api_smoke_test() {
  if ! news_enabled; then
    info "News désactivé; configuration disponible dans Web Admin"
    return 0
  fi
  local result
  result="$("$VENV_DIR/bin/python" - "$CONFIG_FILE" <<'PY'
import sys
from pathlib import Path
from pulsedeck_hub.collectors.news import build_news_client, normalize_news
from pulsedeck_hub.config import load_config
cfg=load_config(Path(sys.argv[1])).news
if not cfg.api_key_file.is_file() or not cfg.api_key_file.read_text(encoding='utf-8').strip():
    raise SystemExit(2)
raw=build_news_client(cfg).fetch(); payload=normalize_news(raw,cfg)
articles=payload.get('articles',[])
if not isinstance(articles,list): raise SystemExit(1)
label='GNews' if cfg.provider == 'gnews' else 'NewsAPI'
print(f"{label} {cfg.mode} / {len(articles)} article(s)")
PY
)" || { warn "Validation du fournisseur News existant échouée; Web Admin permettra de corriger la configuration"; return 0; }
  ok "Fournisseur News répond: $result"
}

validate_runtime_import() {
  runuser -u "$RUN_USER" -- "$VENV_DIR/bin/python" -c 'import pulsedeck_hub.main' >/dev/null 2>&1
}

hub_health_check() {
  "$VENV_DIR/bin/python" - "$LAN_IPV4" "$ADMIN_PORT" <<'PY' >/dev/null 2>&1
import json,sys,urllib.request
url=f'http://{sys.argv[1]}:{sys.argv[2]}/api/health'
with urllib.request.urlopen(url,timeout=2) as response:
    payload=json.loads(response.read().decode('utf-8'))
raise SystemExit(0 if payload.get('ok') is True and isinstance(payload.get('version'),str) and payload['version'] else 1)
PY
}

wait_for_hub_ready() {
  local attempt consecutive=0
  for ((attempt=1; attempt<=20; attempt++)); do
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null && hub_health_check; then
      consecutive=$((consecutive + 1))
      if (( consecutive >= 3 )); then
        ok "$SERVICE stable et Web Admin répond après redémarrage"
        return 0
      fi
    else
      consecutive=0
    fi
    sleep 1
  done
  return 1
}

restore_install_metadata() {
  local backup="$1" had_previous="$2"
  if [[ "$had_previous" == "1" ]]; then
    if install -m 0640 -o root -g "$RUN_GROUP" "$backup" "$INSTALL_METADATA_PATH"; then
      warn "Métadonnées d'installation précédentes restaurées après échec runtime"
    else
      warn "Restauration des métadonnées d'installation impossible"
    fi
  else
    rm -f "$INSTALL_METADATA_PATH" || warn "Suppression des métadonnées d'installation incomplètes impossible"
  fi
}

install_app() {
  local tmp old pip_log metadata_backup metadata_had_previous=0
  tmp="$(mktemp -d)" || { fail "mktemp échoué"; return 1; }
  if ! extract_payload "$tmp"; then
    rm -rf "$tmp"; fail "Extraction du payload embarqué échouée"; return 1
  fi

  install -d -m 0755 "$APP_ROOT" || { rm -rf "$tmp"; fail "Création $APP_ROOT échouée"; return 1; }
  if [[ -d "$APP_DIR" && ! -f "$APP_DIR/.pulsedeck-managed" ]]; then
    rm -rf "$tmp"; fail "$APP_DIR existe sans marqueur PulseDeck; remplacement refusé"; return 1
  fi
  old="${APP_DIR}.old.$$"
  if [[ -d "$APP_DIR" ]]; then mv "$APP_DIR" "$old" || { rm -rf "$tmp"; fail "Sauvegarde temporaire $APP_DIR échouée"; return 1; }; fi
  if cp -a "$tmp/hub" "$APP_DIR"; then
    : > "$APP_DIR/.pulsedeck-managed"
    rm -rf "$old"
    ok "Sources hub installées dans $APP_DIR"
  else
    [[ -d "$old" ]] && mv "$old" "$APP_DIR"
    rm -rf "$tmp"; fail "Installation des sources hub échouée"; return 1
  fi

  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    if python -m venv "$VENV_DIR"; then ok "venv créé: $VENV_DIR"; else rm -rf "$tmp"; fail "Création venv échouée"; return 1; fi
  else
    ok "venv existant: $VENV_DIR"
  fi

  pip_log="$(mktemp)" || { rm -rf "$tmp"; fail "Installation Python du hub (KO)"; return 1; }
  if ( umask 0022; "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check --no-cache-dir "$APP_DIR" ) >"$pip_log" 2>&1; then
    (( VERBOSE )) && sed 's/^/[BUILD] /' "$pip_log" || true
    rm -f "$pip_log"
    ok "Installation Python du hub (OK, umask 0022 isolé)"
  else
    (( VERBOSE )) && sed 's/^/[BUILD] /' "$pip_log" >&2 || true
    rm -f "$pip_log"
    rm -rf "$tmp"; fail "Installation Python du hub (KO)"; return 1
  fi
  if validate_runtime_import; then
    ok "Import pulsedeck_hub.main lisible par $RUN_USER"
  else
    rm -rf "$tmp"; fail "Runtime Python installé illisible ou incomplet pour $RUN_USER"; return 1
  fi

  install -d -m 0770 -o root -g "$RUN_GROUP" "$CONFIG_DIR" "$SECRET_DIR" || {
    rm -rf "$tmp"; fail "Création $CONFIG_DIR échouée"; return 1;
  }
  if [[ -e "$CONFIG_FILE" ]]; then
    ok "Configuration existante conservée: $CONFIG_FILE"
  else
    sed "s/@LAN_IPV4@/$LAN_IPV4/g" "$tmp/pulsedeck.toml.in" > "$CONFIG_FILE" || {
      rm -rf "$tmp"; fail "Création config échouée"; return 1;
    }
    ok "Configuration initiale créée: $CONFIG_FILE"
  fi

  install -d -m 0750 -o "$RUN_USER" -g "$RUN_GROUP" "$STATE_DIR" || {
    rm -rf "$tmp"; fail "Création $STATE_DIR échouée"; return 1;
  }
  configure_admin_block || { rm -rf "$tmp"; return 1; }
  prepare_config_permissions || { rm -rf "$tmp"; fail "Permissions configuration invalides"; return 1; }
  ensure_admin_credentials || { rm -rf "$tmp"; return 1; }
  install_master_launcher "$tmp/pulsedeck.sh"
  install_privileged_updater "$tmp" || { rm -rf "$tmp"; return 1; }
  weather_api_smoke_test
  news_api_smoke_test
  if news_enabled && python - "$CONFIG_FILE" <<'PY' >/dev/null 2>&1
import sys,tomllib
with open(sys.argv[1], 'rb') as f: c=tomllib.load(f)
raise SystemExit(0 if c.get('collectors',{}).get('news',{}).get('provider') == 'gnews' else 1)
PY
  then
    info "GNews rate-limit guard: pause 2 s avant démarrage du service"
    sleep 2
  fi

  if [[ -e "$UNIT_FILE" ]] && ! grep -q '^# Managed by PulseDeck deploy_hub.sh' "$UNIT_FILE"; then
    rm -rf "$tmp"; fail "$UNIT_FILE existe sans marqueur PulseDeck; remplacement refusé"; return 1
  fi
  install -m 0644 "$tmp/pulsedeck-hub.service" "$UNIT_FILE" || {
    rm -rf "$tmp"; fail "Installation unité systemd échouée"; return 1;
  }
  ok "Unité systemd installée"

  metadata_backup="$tmp/current.json.before"
  if [[ -e "$INSTALL_METADATA_PATH" ]]; then
    cp -a "$INSTALL_METADATA_PATH" "$metadata_backup" || { rm -rf "$tmp"; fail "Sauvegarde des métadonnées d'installation échouée"; return 1; }
    metadata_had_previous=1
  fi
  if ! write_install_metadata; then
    restore_install_metadata "$metadata_backup" "$metadata_had_previous"
    rm -rf "$tmp"
    return 1
  fi

  systemctl daemon-reload || { restore_install_metadata "$metadata_backup" "$metadata_had_previous"; rm -rf "$tmp"; fail "systemctl daemon-reload échoué"; return 1; }
  systemctl enable --now "$UPDATER_PATH_SERVICE" >/dev/null 2>&1 || { restore_install_metadata "$metadata_backup" "$metadata_had_previous"; rm -rf "$tmp"; fail "Activation de $UPDATER_PATH_SERVICE échouée"; return 1; }
  ok "$UPDATER_PATH_SERVICE actif"
  systemctl enable "$SERVICE" >/dev/null 2>&1 || { restore_install_metadata "$metadata_backup" "$metadata_had_previous"; rm -rf "$tmp"; fail "Activation de $SERVICE au boot échouée"; return 1; }
  if systemctl restart "$SERVICE"; then
    ok "$SERVICE redémarré; validation runtime en cours"
  else
    restore_install_metadata "$metadata_backup" "$metadata_had_previous"
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    rm -rf "$tmp"; fail "Démarrage/redémarrage $SERVICE échoué"; return 1
  fi
  if ! wait_for_hub_ready; then
    restore_install_metadata "$metadata_backup" "$metadata_had_previous"
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    rm -rf "$tmp"; fail "$SERVICE n'a pas atteint un état stable avec /api/health disponible"; return 1
  fi
  rm -rf "$tmp"
}

check_admin_runtime() {
  [[ -s "$ADMIN_PASSWORD_HASH" ]] && ok "Identifiants Web Admin présents" || warn "Identifiants Web Admin absents"
  local result attempt
  result=""
  for attempt in 1 2 3 4 5 6; do
    result="$(python - "$LAN_IPV4" "$ADMIN_PORT" <<'PY' 2>/dev/null || true
import json,sys,urllib.request
url=f'http://{sys.argv[1]}:{sys.argv[2]}/api/health'
with urllib.request.urlopen(url,timeout=2) as r:
    d=json.loads(r.read())
print(d.get('version','') if d.get('ok') is True else '')
PY
)"
    [[ -n "$result" ]] && break
    sleep 1
  done
  if [[ -n "$result" ]]; then
    ok "Web Admin répond: http://${LAN_IPV4}:${ADMIN_PORT} (hub ${result})"
  else
    warn "Web Admin non joignable sur http://${LAN_IPV4}:${ADMIN_PORT}"
  fi
}

check_weather_runtime() {
  weather_enabled || { info "Weather désactivé; configuration via Web Admin"; return 0; }
  command_exists mosquitto_sub || { warn "mosquitto_sub absent; Weather MQTT non contrôlé"; return 0; }
  local expected payload attempt
  expected="$(python - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import sys,tomllib
with open(sys.argv[1],'rb') as f:c=tomllib.load(f)
print(c.get('collectors',{}).get('weather',{}).get('hourly_hours',48))
PY
)"
  [[ "$expected" =~ ^[0-9]+$ ]] || expected=48
  payload=""
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    payload="$(timeout 3s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t pulsedeck/v1/weather/hourly -C 1 2>/dev/null || true)"
    if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);h=d.get("hours");raise SystemExit(0 if isinstance(h,list) and len(h)==int(sys.argv[2]) else 1)' "$payload" "$expected" 2>/dev/null; then
      ok "Weather hourly retained présent: ${expected} records"
      return 0
    fi
    sleep 2
  done
  warn "Weather hourly retained non observé avec ${expected} records"
}


check_news_runtime() {
  news_enabled || { info "News désactivé; configuration via Web Admin"; return 0; }
  command_exists mosquitto_sub || { warn "mosquitto_sub absent; News MQTT non contrôlé"; return 0; }
  local expected_provider payload attempt
  expected_provider="$(python - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import sys,tomllib
with open(sys.argv[1],'rb') as f:c=tomllib.load(f)
print(c.get('collectors',{}).get('news',{}).get('provider','newsapi'))
PY
)"
  [[ "$expected_provider" == "newsapi" || "$expected_provider" == "gnews" ]] || expected_provider="newsapi"
  payload=""
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    payload="$(timeout 3s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t pulsedeck/v1/news/latest -C 1 2>/dev/null || true)"
    if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);a=d.get("articles");raise SystemExit(0 if d.get("schema")==1 and d.get("source")==sys.argv[2] and isinstance(a,list) else 1)' "$payload" "$expected_provider" 2>/dev/null; then
      ok "News latest retained présent (${expected_provider})"
      return 0
    fi
    sleep 2
  done
  warn "News latest retained non observé (${expected_provider})"
}

check_runtime() {
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    ok "$SERVICE actif"
  else
    warn "$SERVICE inactif"
    return 1
  fi
  [[ -x "$VENV_DIR/bin/pulsedeck-hub" ]] && ok "Entrée runtime présente" || warn "Entrée runtime absente"
  [[ -r "$CONFIG_FILE" ]] && ok "Configuration runtime présente" || warn "Configuration runtime absente"
  [[ -x "$UPDATER_WORKER" && ! -L "$UPDATER_WORKER" ]] && ok "Worker updater root présent" || warn "Worker updater root absent ou non sûr"
  if systemctl is-active --quiet "$UPDATER_PATH_SERVICE" 2>/dev/null; then
    ok "$UPDATER_PATH_SERVICE actif"
  else
    warn "$UPDATER_PATH_SERVICE inactif"
  fi

  if command_exists mosquitto_sub && [[ -n "$LAN_IPV4" ]]; then
    local payload attempt
    payload=""
    for attempt in 1 2 3 4 5; do
      payload="$(timeout 3s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t pulsedeck/v1/system/availability -C 1 2>/dev/null || true)"
      if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);raise SystemExit(0 if d.get("schema")==1 and d.get("state")=="online" else 1)' "$payload" 2>/dev/null; then
        ok "Availability MQTT retained = online"
        break
      fi
      sleep 2
    done
    if ! [[ -n "$payload" ]] || ! python -c 'import json,sys;d=json.loads(sys.argv[1]);raise SystemExit(0 if d.get("schema")==1 and d.get("state")=="online" else 1)' "$payload" 2>/dev/null; then
      warn "Availability MQTT online non observée"
    fi
  fi
  check_admin_runtime
  check_weather_runtime
  check_news_runtime
}

print_summary() {
  printf '\n========================================\n'
  printf ' PulseDeck Hub deployment\n'
  printf '========================================\n'
  [[ -n "$LAN_IFACE" ]] && printf 'LAN iface  %s\n' "$LAN_IFACE"
  [[ -n "$LAN_IPV4" ]] && printf 'LAN IPv4   %s\n' "$LAN_IPV4"
  printf 'Web Admin  http://%s:%s\n' "${LAN_IPV4:-?}" "$ADMIN_PORT"
  printf 'Mode       %s\n' "$([[ "$CHECK_ONLY" == 1 ]] && printf CHECK || printf APPLY)"
  printf 'OK         %d\nWarnings   %d\nFailures   %d\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  if (( FAIL_COUNT > 0 )); then printf 'Status     COMPLETED WITH FAILURES\n';
  elif (( WARN_COUNT > 0 )); then printf 'Status     COMPLETE WITH WARNINGS\n';
  else printf 'Status     OK\n'; fi
  printf '========================================\n'
}

info "PulseDeck standalone hub deployer git-006"
detect_network || true
check_prereqs

if (( CHECK_ONLY == 0 )) && (( FAIL_COUNT == 0 )); then
  ensure_user && install_app || true
fi
check_runtime || true
print_summary
(( FAIL_COUNT > 0 )) && exit 1
exit 0





__PULSEDECK_PAYLOAD__
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
