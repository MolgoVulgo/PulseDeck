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
CgDoAwA=
