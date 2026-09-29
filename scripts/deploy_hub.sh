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
H4sIAAAAAAACA+39y3YbybUoirqNr8hCPQi4ABDgSypQkBZLYlVpW68lUlX2ornhJJAg0wIyUZkA
KZriHW7dMU73ntM5vTNuY9/t3bjjNs4Yu7/rT/wldz4iIiMiIxMARcnlZXItl5CZ8ZwxY75izhmt
9d989L92u71xb3sb/8U/+1/H75321tZvvO3ffIK/eTrzE8/7zb/oX2v9bH6y/qtb/52Njbv1/3Tr
P72cJvGfg8GsNYsn44+w/u0d2NBF67+zvWmuf6ezvdX+jde+W/+P/nd0Mg/Hw2Z6mc6CyXElCX6e
h0mQej3vqJoGs/l0Fsfj9GHv3nb1uMJlT/zB2yAaQhGtRIu+9SfBzK9WKkcCnY4rkT8JsOR0Pk6D
YTB42wR8q1bOgyQN4wi/tFs7rXZrGJy3q5VhkA6ScDoTn15hpSdQyXvtp9OTIEkuvVehN/RnvkfN
yOE2p5ezM67zsLfZ6mxhU1MYZBANQp5NxYO/6tQ/i5uTn2ezh72NVqfxYLPa4A8jH/BgGj7staE2
fMB/NuTH+Xk4iJMIP25v4bftbfh0nM2zxcNOjyvGPI2J9+FFa+KHURf/g0BCwLU0EE4BsP5pkLZG
YTQ8rlycBUnAC5EMAPofcf9DB+u/Jvp/b6vTuaP/n47+4/obiLr+D13/zsbGxs7d+v8j17/fD6Nw
1u+3ppcfnf+3dzrW+m9tbm7c8f9P8VetalwWORS8qFT6fcGg+32bRf/m7u9fYf/7w0kY3RIXWJ3+
b2527uj/r2D9b4cLLKT/W9vW+m9vbWzd0f9PRP/3cKnDdJb4pHftvXq6/uapJ5QR4gd3ZPJfdP/7
0+ktCIAL9v/GxrZN/7e2gCTc7f9Ps/+/89MZbHovDRKQ+rxxOAoGl4Nx4I3ixMuEQyITLB6Oknji
9fuj+WyeBCAihpNpnMw8P4riGRGRtFIR78bx6WkYncrH2VkS+EN8QW3MLqfwW9bfiy5F28IaIz+I
EcpGhDlGlG0l8XwWpLJsGEHV8bjPbyuVyrOX34MMK8bROg1mz+BnkNT6fbRN9ft1KDMY+2nKMzwg
KHTJ8DMMRp5kgbU0GI8aXjKPZuEk6OJg617zofcijgIujX9YqCXKQK/il/kZNhV8EnOqzcLZOOhV
LThXG94wHqT9eTLuYQ/QcQAvtOd4GkQAIvWmrjoxIVCTfaqxZyUHcTQKT2EwAqKtx/SipgroY24Y
b8/idNYTDba4nRbRjNYYWEkQmaVxZdyl8YtZFlaqPw7Og3GveuEnESxa1SzgDwZBmvahXO87H6CW
fa2bgBYInU2P17bGA7AK9xk1obTC0dYh/aoBgQC06Wlt4hI3PMSfnmbZ9OXK+cEkjnqHyRxgrRAJ
6cyMVsOBN4CkrTAaxbXqARbDTfFTcMK44AFTPpvNpt319S/T7pcp9KCjmRP6JSUQ4u65t3iIxpjj
adGQdXCkZ/F8POwH78IZABAnnmHjyOwjTPv+ODwPavVuHs1koT/HYVTDoQMK97Zb7fqdCPIP4f8D
HyhJfPqBMsAC/r+V1/+2N+7d2X8+Ff9HqhgOAk8stodnOHTEgvx/dhbYMgDQvfPwlPj88uJAEbuv
IJnhs6OUx9EX42AudBH4MISkD6s0A647DAezI1BVGlj7uGEUAX54Mg6GXe8kjsf8KQou0rKq9L2o
3jSJz8MhyAJABpGLVPEtsFxgR0QOkdQema0eM00DqLwOABgREn1oW8DNACwAYRxMgmgWDAFSQ286
BnjB70E8HgeDWZykDFxsL+HGjhTBvDJIZzUcVrteVcDB4pbVsX8SjPH7T+7v/rkfjnGUUAYpt/WZ
oAefjIVAMaomPjW86jBMCYTVulVZgFarLt5Y5SSocZgvQbARQ/VeRoH3GGQZb6vVtscN+mqUIiJh
pR8OD18d5GY2n53hRxRu3waX9ufzMLhww+26UQ5pRIRCML9wfFwSxhm6rg5gHZVLoPs9DQ+5soHj
Xg/w+5Tm5QWw23kaALibQ/33zb1p2PxdMdwtKC4C+nTQPwWBqxi/Xz32nAV04FsCowH9qtiC1UIY
u2prwCXBvBhcjs8CVo4vAkjml4UgSkKgJyUQcn//1wEQGrr6LLMWAuk5lPHcZf7TAeq4Ui7/sQr5
oSagcvlve2ejvZGT/zp39t9PJf8hFfeEEUWKfM/2XjTjaHypyX6+aSYmSjLyB8HKJqE/p3FUYB6K
U25oChx5HJ7IVl7BoyySns1n4VjZk9C6cgNTUsPDWe+/GwTkbNTwXgc/z4N0hj9gl0VpYNRuJeKt
MjP9cPj8mSza8P7LwcsXqqIwS7VkUe0wVX7ShDzkgrIk8tz9JIlBmmSRmHj0YByCmNjwojiZgOr8
l4BeO5oSgoxsTROkHosmxKPo4zSIB/Ew6I/jgVgi1SbZhUQ7LIg/2f9u782zw/73L/Z/Ouj/bv8P
/Vd7hz80jG/4CYBb8PXlq/0XP+3D6/3XVgmcN5ue+FmOWnvFkKAXfRxlf+JPccFNFcBZoC6nJZCt
Ty5XcnbPXn7fP9h//ePTx/sHaGUbAKDQtqSAMZ+CzB54CmH9YZ9f9aWhDcn+PG14gEHzQH5MGKFE
K1K3Eq04FR5RNA0G8yScXZrgf/zy5e+e7vdf7D3f5ym/2js4+Onl6yf9H/YOftBgebB/cPD05QsL
wvLt4eEzfhFEKW5UwGjCTBCP+f2Zn571p36aXsSJkCMn/ltVkN8APoejS6uYeKkKSrCngJv+qQKg
AI+2ng35DmYOmo56NBdVtDZXO3nvyfOnL/q4D5c08pI1F4lPP0D8r/GydZGSNUA3S1MYJel6pN0Z
9KGrq2HGF9FKHzdSTyLCEBS9cNwTbaq+0bSlgNZHSNeoK+iSO5gll5lRTPSWX+cWtTML3s1qQQT9
wox71fls1LxfrQO0k3BaY/teQIP0Xh7Qfvf8FN9oHfghCPo6RLbbm6BssLIKSzGErRCCoOL5SQDU
B23rIb4AEgSaiEcLAi1m0yNnzD6KIjWB/t2MsGqoBqr2JXAby6g4i98G6MIpqgIVit+GIH2gKqSj
P6jXPD9UYmBUXA8miA8mFtbom9F3vQwAW+0OAgAmgFNnquiJecGU7ZlO5szb+qdzPxneZM5OoJnj
lVOVYDmD1Qd+whriu2Zmfh6kyQiW5TPQ5DrV8lniMj8PoQ/gmKJdj+YgIBsnIWwkbS2MTvmrKIoH
AUUF8Vu2VqJRNHZQJfzB71oJo211ncc/ql7J9ubJuJUOzoJJcN1dX7/CitdLTO5xEqdpU/QoZ5gE
6KurLySTFiCEQ0F8aih5dEngkFvTe6/jqL5Dz/3xHE95sM4NN2Vuu2NXOrHhPgC56YMcNoAu1Glk
TT+WAuEhHl7aBi+aDvC9cXBksldtjsJ8BfwnAfzPzq/kAYLojcfnX0CBTMvSlBvsnhFAvmvINlvi
jWbHMMwTeKolegH5MxgAe21uaWoUqGmzcDYfBkY36mXWj3yldzSOo1NHZfVWqy3fmdWZIBBLsZrQ
v+jNaO/1pvDgDvZ2fxSSLgkrUJN19E+47mXSkzE6Pzq1gIInZxpAolO9vHjfJzkesMyom/uYtWN/
0ts8i2G7XrqbtL9lLVpf9AaHwEYL2rM+Zc2ZHxzDw39S19j4Q25g9Do/qqF/mTpGRK/t0eBLvQVB
kfriiMtoxv6WtWV9EQ1e5wmTog+wQ0tE4xrsYYMo/YjEZllhYavdJtpRg3J1TRqg817e0niamk1M
YHbGEFSpMCXejSSIuALJGimJ19EgqMly1F194ZhkR94EdHvvBJrEesjqUEaYj8diBFikpwYhiTQO
rLBvttTbNchg6uAlri2tJq/WSJJENXMUFhbOUbeSC/s2glHKKt4FSDBSj8IPkhLXdeaixtDA+pK7
zBDHJGNRRbqWVkbDVNKyyWsEGyGlE0CcU0RrWscCOD0l6mTchxuQFKcm5Q3clNlX3AzjMApq1c4Z
7JWOIRpmu3Dm2zDVdWFF8Typ6KNvBAjxEWImBRyZkNP4Xvw2Z9SvzoLJNEh8soUM4LM+jqP2Me8H
LKQb9Ks4lb/AHtAqyFd5KgaaKmgRSIHGQVTjl9S+IgtiOUnTQvRDMaVmHGrR0qGsY+g3bk1f27D5
04IiA4Acg6zYJyurYxBKBRJj0M4pFh9R5MUiLLWaTKSZIFYQiMgQoxG8xCB4SrDJSLh8ZWBpntwk
y5I61a9N6wS6ZiCRGIA7xyVqWJC2ByyInBuZ6h9PIlQAyb5OYkuCoxdZg/iotwZMM7k0KvCbrAY9
61VS2E6DwGTv8l1WTbwxpKoYEMTqTb7TZCh+Y1SENTqN7ZrypVZVvDJGG/jJ4AxEHnO86q02YvnO
EGdiDEi0ZBnxThNk+I1eEbj9GGTkvqsB+5u23uYXvUGUIYxW6EVWlYQXxGaDasZGFXjMKsziXPFV
5eQ0Tmb9k0sLFfidjgr0Rq+IkoY4K8pqqpdZVflKrzvx3/XRDWwwtpDQ+KChvPZab8cpOTtkZpe0
fJsyaqHSkyNPywm1RdbgO4n2I0u0Smj9CDLtqHplCwpZg4rVXBeLuy/oKGV1WZekBU3Q1WWBhVIu
c73ccU2RiNsaBbPBmZBlp/4lnicgQhtnO4jGjWzEXFjubzI4UT2BhJIcCI6PvAVt4SAVKpJgoYB8
3yAfJrHcbao+ChPavbMx7jNZMJNZ8UOV2uOOcIEdLUOFBoFLNG6btRbIz5oAkEcBR7m+PL1fAoF0
isSj7dNUsC/812AtM38MknY6H8+QDhtwNz8abCyDIVTSnizJPMFjgijArAl0UGCLrNMkGIXvMvQr
djiTDXSdZTCHwDGvLtCLdD6CVhuwS4C8emHkIe8KhrLvFmZHEEjcUiNMI3+ansWzGo+p3gpBe0lr
dYN2XfQzhKbWhRjML6uZ07F40/XiE7TIolydVdY9hzXM0krYVDPHKqx+oH2kNS38neoN1Y0agmVQ
UTzQfRLgoY5lps037Rq6XA/0mw+ioelQf5VrrMprgkyRFydfYhZPQ9QkNbjyq7qj8HR+AnhwBuvm
z8w6xhdX1Z/j1KyBL5x9iFVVu8Isc2055Yt9LwEjtwDnHcG0IUk4SGuFVHYSTEDo7SsHHIC7eEXb
EB7bBfb5VFf6QM7B3XCVjQ53BJoPcCOgJlyrrgOlGKxD6+iPX62XG/anY9jXUD213dnxQFXwBvzO
JWvVbmaiMEd5BBVwaDBCxFDJiUW9OtDTuoZdOWBwI7xiz4PJnnJUanjture+7nXaG1t2AxJ0VuVD
fJ2vKLZHTZxcNDTZSps7Hm9y+ECYvoW22V2jhU/9OS49HfIUsAJ7Yv3JCeCX/baRq8CkWC9Mb3Qd
B/sfJUHQP8VSCRD6YQ1ftvClt+7VcJ6//e1mHdfHrsjt2zUZfM6qksRboThADbqZB0pJKJF2/ke0
1D6rr9mn/CJm498wYG8SDofj4MJPANYYNyLA7aeX0YCjOoSHQV8c1jkOLvHgBUSRd7N61/M+R+ca
GGd4CmJKcBTFTRg5vBk2obVj7QRLmM5Abrjww1nWiOygnisrzwuPqr9vgsg1A8LTPISmmy/pdD2t
HpPjdZxG4WhULa3+XeJPrHpP9l/8oazS62AE8meQNF/F43BwKTtrJuJ9Wd3H/uAsoDEn8VjVRGeH
oLSamOSBWAOjawCnD9JEM00G3hoGxKztAqu7HAfaG29tHqX+KGiGERIWLEG5h0qLgCQfAaM1Gh4R
vJC34qBTby0C9Fur2geSiXJrUghGhGK92lDf+hQ/19N9ouoqhiiMhsE7y9FBa19347B6ALl5HQA3
np1Vs+b4RTGn0CmLJlt6VeGEhUJi5pB1rXU6jVPZK57Gr4/j7JQ72zz0NrdjaDhy7tlAUFVU20Ee
aaOAUasbFBMdQkzToXhZtUV3LOKWrAsMitJHh6VI00tCftRKOZ1UbFkLxcR0HATTWrvV2TbZWZFT
xdMI2Ew41P1KqnUX7dB96WraEl47qEcagKhKbiKmiJXzllKcT/NlquleFnaxd33gVb2c25QKfwS6
iv6Rvbw3fwrbKgXxuFdFHj6YWU7ARHyDnsMBGM0fPdxXjnjG4s3owFq0yGQbhl8si7HLOqR8wKIN
g3EwC+S6GZ49EgQ3mXi2ZawdOzjzo9MgQ3YnJIpIyQJfnwLILLPv83tV29vdhXuqre0prKjBLDuu
yJ/oW1ASrpVGUXh2FcuPV7RZTlpUoWUoS6E7j5iRopVhCnyFJl86QpiKS1ksgucLgITeheb5Vahn
klJAdkHDdRK7zmottkaubpGk0QQTjCV3+AhehLOzPmuTtWprNpnqc4BarQuQPgJNr4EpfO1V/4in
BTk9R9WM09bgbBIPa9gEaAjxTrttfE2C6dgHwPP3/LjqJTz62ikAsE+lRs/4xQ138RJUjYI4tKM+
FjhaygKSn4IVb+GSM6yYjPkUm0arahzRGS4wnFqb9FMKe6ZzX9gdXpOHc1Sl0GxW24/tIDC02EAb
DruCkPvoDM5l31HfMSwbmGnNpemTF1/XPvrEZlr4yWUb4DAVV418vD8fliDTnALmFFRT3y0rgwUJ
GcrXlWCTL46tgnSMrErRk12Eo/kBrFWOqc+PzIy4L5h1FnRvD5ZtH4gnthVEi9PJYvGFV7SwtpQL
wJp1SoxG1AadZfAWA/bz2CzqHFWF0opQI5/qIof3/E6QZjDXPuYmtH0snb4/8nYWQ7Oh5xYkuNQ6
QSk/VHr9KcSHgkUD7CCn9g+bnFhEzCKhua5vtDdy8xUlP8WMJT6uhLGYWkK81eNl2QVai9VbyGS/
Qd4fs+gSAiOUIR+pFKXGl17WniZonWGYH5rQzHGI96ZoIguzIz2QFY4Np/De4Lx6vdwwD89I9KGF
Yfd02e6AYq3wdJCHP2RxQaURKRNiKHIFyYUrhKUmesiJM9+F42D/HZC/dDWZ5ptSmSZnZ3zNCJG3
Ojo7xEwq3FH1DZ0DerOYp+VNk/AchnyqVrjrUTYVHMiCQVNkRMmgM4Kb24s5+irAStSVAb8KHRVB
Q4ZEJF79emUiNehuWa4HQ00u5d86kTR901vOEHitRRevdzSHxYrbchXOH0+SCp/j5dZ6ar6FuJb4
mJ22/WoXdOBPZ+QYQAdMttj6aeXTW5cdHQPNXNlWRbuqsGB2l0DpqjweQ6Gw8HS4kY21Xj4lIeWu
Mp9yvM9Npmg3LT0TaqB4Gu49g+GZpoUrdQZfEY1R6VtY6BmHk3BGKAvvNkB9va0tFSpCzPIH9Ebe
EfKl4Pt6vOlyVok30dsovohwmrKx6pIEFxeKfzUKCfKRAMxv9ZEd5zIXgPBJxbUI2Zpsm4Hao/8u
JHgCd9cZ4bRlNCMVPh7tuygPbCoGqpbNprUw08pFAUPQI5guVJiSXUaLVLrIopFypcyApAsz4CjX
Lzk+XpCHo/XNEQx0kYv0serkg30u7FAeq0YumufCCtZx9yDjdS6MgBxn2yIm50ILu7HK5b0aL2yf
RdsOIDzdMm+4KqeKqjkc5C5Mx7iCzaApZXI3iFj8nPFabgrx/Z/CeC1NwdZX3fe6bhqN8fOR+HQs
fR+Wo47PBMp7VLvAaruE9+Yn8Z8sEB7yzpQajA3XyQ8ICSrT/4QXG0w+lxOi5lybBju4yBSNBfOy
nYFtHU8PwVlSe9xub5QqYsqsnHntiV8LNiB6ghbuPvz4L3BuZLjIwjiKA405niY3qJwDsI1mjnN5
ldtMvbGjpzjhbT7wqX29CKNxDu5wNp4ioF21Ws/ZDzgTq9xLKgQGW/LS+WAQBENjP5kHldDvR0T0
UiQ2ZKo8Gqf+eXCHxuVovACFnX6mq+LYslhxA8ygc7jxsK9SO5ukub8oV4HRiATfh/ExPfLMGT9Q
vIvzvi8W69aYMPMp+aVAisA/I9tMTY6uYTdgLpkzJ03NAdyc375tM0oCOlKR2LKI+kjgs5AD+34c
GrRH4JJKSONEJCfWujBDOxXOsKjsRDh3MuwESTve2WnnK2FSEIFmWsBMfqRlqyYayDcejKF5Wa4V
kJ3ahQ46irbm6DH3tlYvBFbp6tlr4XIbF+6xZdubYmEeG+uOsBFr3/Wu0PmSdn9L5je6rpbJQguO
2NEGk1fHtRirj6eLRyUxtcso4tFiRTwqUsRFHGlEAaPWNxkzGnFsqG09UeGhkQwCtRVqFQcayWhP
u0QW8BmpqM6clSYL7Iyy4E1b9VXhl5GM0rStN7lAzcgOw7RqiEjMKAu5tNNRxvRZBFi6TQ2Ry9SQ
xVNGMmrStlpmgZORio60184MkIyMCEirrGZwiFoFpoa8WSC6TbNAVGgW0NtKzcYcZluZgXrZnkjK
ahkR9LKJ8sD9usvQfirsyTfu25UywMwyUF9g0V6YXLg0P3GBCkj0z6n/EQ28U/70dAoFmt+yVooP
CfLEWB3fVMcWGzWUCmhGedIsi2QvCiQtUPvwzLgB/5OxkbW0zp7w0JeZ9kEEJdbNr2bMYX0FJVJl
B/0YGmReBrB2wZ3uWLYLpAVQqEwrKC1ASgs0l3K1FPVKvdel1VTHPijRUcuR7h+poC6vVpaqsirx
wD+RFmqI5jdXQQkTSmmgU/kUXjMOsn2nlP5DlVLHev4TaKR3dzD9eu9/kpGiH/X+153O9j07///2
1s5d/v9Pdf/TBG/YwQO/seebqY/PgvE0SNJbuQnyxE+DnS35hMEy4/BEPU78get+gGUuBCDimxo3
AlQqr7793ZPvNvpPD/df7x0+ffniAL19ttp9wK+KFtUHbzsb3m+9nTb9p8LRqAeHe4f7/SdPX2Ns
DScFOPeTdRhAtkt4hwDTyQe5QC27nXVPhXS2cOrVih3B7a4kROQWygIVLVQO/ZmyDStKqUR4Jztb
QY2i+vWs03aOPV4QzLCMwcJUiQKBuGZdJmU+qfaq9daQkmGAzJMOwjBLoAyVhrInmaaEelzQk2iO
sxt/7UEXAP9aE5PWcO/el95WXXZjRlbJH9Rjw/ttwwPxgLlSKh27cstvQgCYMHYlW6p7DwAN7ARF
madxjYNBstgwysMkMkR6/gwa8+EFYNLgzE/8AQxH+qelPqmgAklblI+8TxCqdXaEsTU8DSiHttgT
renJ2+Foo497olZNz/yN7Z1qQ3XeEqskpZ4G9aEDwUivMKqK5rihL66yctdfXDGqYAN19cTjqV9L
dCoKFhbwF9Fj2vqDTuPIlu2PT2PgJWeTBidRSHngJNc1BBDogTIeUJtWFozqFwCGTUMtUo2Sz50x
06rz7JnibrMWFCxk6g0ameYny8vHeK6Gqwu6U/JPVWW0eRiJyGoZNjU8zHBgJ87IjQ/QaE7pOT4K
WmArIA5Ppj7QbR50jXtsqEnJ7XcaRNiGFkJr7qbPvc592DPREAg1oTZ+3djy3rx+1sQNr+0KvMXE
S4GtjJsYO4Zmwuk8wn7pOkF9hOaWEbSj1rkvR+XIipElbwew5VJkWLSJRGucPubPezsMkxo/pBzT
7ZFw3o/fintcl8j+ztvaWHYMkXgRz75DtLIyCcn6LtKwuZGh2AiRCzQZTI1eE+pF2nrZ/+n1yxfP
/uC956fHr/f3DuXD/u8fP8tFZ2JEKH4eDaml0RD9iE+qFEVxBos3tnQcfsfKlyDKOu0UZPqBt7kE
4RSLJC16ZuiunulerK0Vpo8AEpyM6H0UXzCh5yytAB92EZnNxpIBaDzeIv1pyqEuuVhLsipd4Pio
UbJSwwsrUxvTSEoSNZxPpmntqjpHW7O8/LcKuwdd4rmbr3FM12jqAuTyMc9Gr1ZtYLFutV6396xg
GeFpRM4vqjfarKDd1eQNKTIRmawvuHJD0QomD8C2eWfXLZZwJRq4bl2p3mx6b1yhIWj9sktRxgey
JF7aPKkTSeZbZpIki8beHjg0U6KLHKrxaRRxCZ5CN3waGceYM8icY644/ZVwUesZ+2Jb1Bw2Mh6x
MBraafmycoiddQo0ZnsVZaSmt8feQ5X2t5BzvYlCBLGWGq3hTJhWxNjuFO5/Lv2f7276uPc/39vZ
2LH1/82t7Tv9/xPp/3uzeBIOPFT0KZR9EBh6fxrM8D76VORRGQLxpysCmbO/efpB9/8tod8ngVLt
g8mUDPvue+r0tK3GXQXA1/ry6pSD/ceoD9KNRUTwob1aUq09mqT1//rHo+w2vT9Kr7Y/Hv8xav32
Ue1RD76//+N/1EFsofPyVdpC06yrIaFG+7QEfZa1Mim2QTom0ONM1UVflS6TbyNj3A2kWZQAEaRk
sEUeLMAL9TEdwVTk+uyNqq0rah7LXSNzhuZ7WodCOBa5SNBeopp1yM1OOdSVdWQpwVQAqO4qMRrP
0zPLII4d48FmTZaBCUexLhFYOU4om3xxipPs6GgURv54rE00d75BeVdyxvzFmoIy06u8sTQCPHag
K+h0hIHfoGdF6PXeesW/8Wz2mGQ3OgFQerp2qxVr3UsdvWGWa25XOCTVSNfVpq0a40Lzk5roWiWY
YZWfTsB7QtBDCSfXBv4jzVB1rg314YdokK9Qy20e2QEuXU+c8jDoAFvxYF75QwsAMh2xbjgx1QZK
8omJdLPUkEf5qzePNWeTkXRTw4SjazPYdmucNpm83OQ3kuzWRigcrV1rtde0GyUKbsVak3f4yiNi
blmGlLlPr2geMi3tSAWj4Rit+p8l19mSy28yEm25xlVprXX5Lmuea8GKGZlyjwz0H5nBbtigpoKp
tvXoN2kgIGWA863Vry13oZGRlN5qlRLUiyQuhvdWvhX0cysYE14nkK9gx9ZpELI/5StbUXZaXetL
vqoZb6fVND8U9kmhd/kO6XVRbxiFl+sJX+YrWC53Wi3ri16VN4Ch4SKZaf05DqMaIZegHVWTCrBb
i0UCMiHCfS+NargAUQ2qgD0c5yb5IWSBW9BogwPlMi+qXEWkiO5KxObyFTiozlmDHWOX22XCSdbd
kLxGxbFL2HPWXU1eouKoJrxpC+rJG1Qcw5QetgUDVbenOFCd3WjdFeVVJ/lqlheuu7p9Y0q+GZKH
nXWzK1PytWaxu468NeUW6Jzw8C1aeL40JV9Nev2666kbUxwIrrkBa9RDf52v5CCHxYTwRiTqdniN
IHSKmGmpmqy4FEuFKBBujGto8yJlw7O1pka5AKXO6xxuSq4RWbR28XB0ratRQsbtgeTudm141pll
1rcwCNL3vPdW3sDNbfOJoMi/BGL+TDoVuqRTo20lFOvS6q/F/jMPP9D0s9j+s7HZvtfZsuw/W5ud
jTv7zyey/+xPToIhBsc/23vRxKTGtquHR9RwBBuSbT1Zym40faytrT34bBgP0AXMO5tNxg8rD/Af
D1lCD1hT9eEDTH/+8MEkmPl0FpgGM6lUircosfeq52FwQb770u7Rq16Ew9lZbxhgnpEmPTTELeTN
FPSgoNepQn90u8pDa9gP1vl15QHlUH9Y6SZxPANqPY6TJt8p3R36ydvdZvPktPt5+6QddDbhYepH
wbj7eWer883GhnzegBf+RmezLV9sQg0o3zmBF6hudj8PvgmGoy14nMxnwbD7+f3gm2/8b+AZZdDu
5xv+5tbWlniE5uCps70Dz6dxDKV3Noab97GxCx/U989HW4PtHXw88eHjaHRv6x7W9QeYfaX7+T3f
3xiN1Ato7puTk/v0Jj3zh/FFt+11tqbvvK02/Cc5PfFr7Qb+X2tjq35d+e3VSfyumYZ/AfW+exIn
QEeb8OYa1+3qxB+8PaWD8O65n9QQOvVrdEu9mvjJaRh127uuIrsEWPFMNoHdEaxiF4ex3mltbXuc
5rI5DxtN9BwMmvyi8S1aRJ77gwN6/A4qNaoHIKMF3pun1UbqR2kzxTOp65P5bBZHgADT+ayRBihm
X1EfYQTcKJyJAlegQoFs0Z3GhLjXLTpwhtG/Ywzqdjr3ASy7Yjr+fBbvTv0h2jq6GxvTd9cgAU2v
hmEKTOiyOxoH73ZP/Wl3A+v8GehFOLpsSsMcJZZqngSziyCIdv1xeBo16W6cLq5LkIhOALowsgkB
47p1ktAl6B0aPC5D0N2AD7uIGc2zIDw9A7C1OnKAbVljKlcAV7bttQ2QE9YxzLnJjpwKIAlZYPNT
ug+d5sd83Yr883zhHSgswbQNvzUk+LzT7mx3hruMSt0ODC+N0b2eh4bzqouPzcQfhvMU1iBbAZgK
YetufA50ZgzYi2tCw/DEkoqWDdTjWB8yQbogIccKk/QQFtYA7sGbizOYd5PWsBvFF4k/Zfhd8Brs
bLf1QbQQjudBfoMwhXDsgOsWkjQFSrxhgV/JpuSXk3E8eHvdOk3CoXqHD7v4nyYaDscgyADWjeeT
KO2CfAQSWA2h1ByFswZQO8wg3PkGULTRGSX1Oq1Yp40YMPCTYcGY6yuvmARqZ1stn8LtNsH4XUaB
8P802tMGeHCO2yaNCUatsL1NyBpcBidJfHFVjtc4DgRvkxBgFCeT7nw6DZKBnwa74wDtjrSmOM5W
eyuYyG71/YaN6Gt9r92W84Et06V9iqzpauEey1WL3xqVkL7DzJGuG+/xBbwHAm+8hmeEE/bk6Pv6
bEObhbYKQCXONvVPm/qnlhCQm8iJza1dTtEIjTYsMoH1mpSR2kaBTZy/3ldGszaXp1nTEMi1HCRf
YtKksTroq02ZkDTeV5u9CLGdu2HTxvhvvvkGWlqIjDzgFq5zfuFlk/yBdsM39xsbnU6js/lNo7W5
XRfV3fjhqL6xtdXofHOv0Wnf0+u78MhVe3u70ens0P+49hCEIuaLSBLFhryXo5fb7S91uAkz5WNs
eddaK0HNZJK5FSjahiRl7RwZE62tjLxbOtXaui3M0EbUJDHTHFcBot7PE52smSGmSRxfWcTFgX0a
vdnWx5GGQ2sYtFGHYSKOfhjYTs5PJUGhLofodQupbXNFNlW4qB5vd+gi2riiJrhmt7Pe7EBfYTAe
ehRFueqq319m3+riBwHyDORFsYc+3xnd80Ee12oQFvKYWAIVD0IQFaJl29wmLiQqQL28/CzR9hsE
VdspwcRzun9OiBba6LqjeDBPzTHyuyuDKHB/rEbUjRZawk3PbEO+dbXCrItKNyl0yGDx2xL5FTh3
c/RKQ+1Nll5PT1fdW4bwi9V5Olc8R/e00/lJiZi0uZKc9I1OcDL5gDG+TX2tyoULpqxLH4IDE2Eq
lPfvOeV9JhMo/XZJBNYWgcF4MtMF8BwOGoJ2x9QMDDiL9f68fQ/0hZFJCVHUhn66Z6gDXBW0sFGn
Qi2+OMNPLleQxUuXkJs9RZ/kq+U1jIUtdmVys6sY5dHZZRf04F2hnkbxrOmPQdsJhtctwTk5Jf+V
RaccYiArENDiCnR400WH70uEwcYILW5lE9zXN0Hb6IPMn1clsjftfKIfaJQwtCe92DdWF/nhOQUe
HTvzBdo7rpkIvB2NBu1BO0dl1FBb6Vl8Yet0SYDRIUETlhtEIV3jnCZBU2y4d5JKbpCVwdCDbXXD
tBJsO7HjbXBJuBQsq/Obm7jt2sQ3wIJ7y4nP4/gUVjQen/hJfrw0GH3AKKW4KZamiBqNesyTiBsx
m97IygAlgWkYWv3n7W/aw87mqkRfY3ZbG2xgUuu6s3F+5lhWWlG2js3D5iSOYs5UfvDdc/jdfB2c
zsd+0ngeROO48ZhG6qcNVY5nkGhIV0IFOtvAgb17uMA7tMoj5iL6PoIF877JBA0JUHNHbW80drYb
93E73a8bS0M6oRpUF8YK/PYsHCtpQTTYFsuDmRTolxTuXbiM38fBeTC+yonO6lPrp73XL56++N6l
YGeF9l+/fvm6ob14/Prp4dPHe88cCjgWEvnK3ZtWLiajoR9dXpwFiVgROgG6UjbFtnsbkA2DwCcN
b/82CYahX8sslfd2oG79Si1zwcqKldxQeG8DVpu0pVhfUw3cGDANzUa6tamZSDuAvR7b5LLCnrAs
ZRYfnh0/1FH6wvUHnBi8vZrGaUg6yCh8Fwx3E6ZerKgzjuHvvzTptlCA2O4Kekw26M2dNot9vsnH
P+/c6wQb35Rt6I36btFMMi6DFcmwkt/8fhROyPuoS72HkdfqbKcekX48DeZBsZFA1B4HoxmZRfSx
CGsRl0advqwwoyqXJftBWWGxHag0HnzG0anJqxziMxUFwm8VXFa1Ij7NOt5bvPUxjjJBaHsbFS5N
Y0X+/hn78vrR7PrfgIfRHbWpJyB6hc4MV5nRj37hRvhDDehWfVc23b6exVoxkhvkt851fpN90+ZN
RmrtSpqsZuMo3JmODne2uEM+l9B1BT56cNva3OcGhPDYeSPTzRuZdFg8LIfazTucdrU5KEmenfvQ
MkAUDR7PFBQVgOUcvL3cRfRoq11/PyeagUS20WlsfNNofbNjERRCcZKHBC3Z0GjJhkEVSDe+rrQw
1uXWbBfX3BywAzLx37riuCkECp5C2+zuZmbc9tJm3Nz8hI1L2+Rbtilr2x7jEtZzF6WgNsRVeB+q
3NyzGrxaUYOxjrh2QGnVbDKO9eFuFlLXHU3Gt+UH9GdRMMTLBS0gyGkZ5Vhvu83JOTpYhmlY2skm
EHkR+FYwF9I/ZZFVp/FNmZ6ipG3gMkO0Xeq9eOl8MkEDgnlWvIuDbJK/APMNXcHkU8QPPTyRZ6yu
0XS7sJ1O3oYzYQxOm/D2bZBYJ4iyKuwZcail9IgbqRGFuCg7WnIr549TsybQ2U1zIOBlJBPTIju8
1MYsm5pSrVhSNXWrFSR2oYd1PkQPkwaC4TdBJwgELUCF/0q3pbWX0obzOsB9lhYy9lXC1A3qWVLO
uRcKmEMB1zeQw1z6ZOKPkeNO4qE/buJaDhOQaywlIIzSYKbx/y1L6ndYKez9ZhkvOhZdIyFis7HT
6LQbrXv3Ga1wKM1ROIaKQMLmSQ1YLZ640lhJ+GG4A3Wv7WzQiXq7/WVdR7lv8tr8DQ7YN3In7Jv2
CTq6o3j3bB+erZ26MWU5+LxUULCiSx6buXxXsp488yjaGseNnFW4OgzxNJilt2DZzPRXNr3r7X8U
M6cpEujduZmnafUspMPsxwqLF0xTpzigJrrFE9UqLGFR0zCj4MhpaWC4rOQFcDZG6bXwv83sLJo6
V94hOS8L1+E0j3TDvdNwjnTSx0qO1rX0xSk6MdBPzzsbG43OzkYDbcbALOquhrSpFJ+05R1ltuQm
N/rotOuaaYF8dL1Oa0MYFgAe6IMeRiN0ijQRpTUEWWFlf4QNe07YSvmMRLP2KgtDht7WCESa4IZe
Cvl2ykfFDef8FH1tTOLA3bTubNyS6Tt/HGnYh4mWinHMgnGALPvyRhqdZQpfSeG6r41C3LUJaOZ0
vZF+Ni5RNteCpzmV7GT7eIdP+0MolshtvqVtc807Y8M6xNncbGxs3mug70sr45vo3OjeXDZxcHmo
aBsLB+W17qcUjOgn2o5iGk6y3MJTuV1L2tNtWNjDlWGXSjAyPqht7rSHwWn9Wi9M+/yq/SVJHobJ
bFt77pSYlmzJS+dRLr8PQ/7JSyVk9SQurktB2+dnNs8uMYNVHqyzI/aDdfYHR5/ihw8wpskbgDid
9qpkEEOH7mF4Lt8BMKsP9RdkBUOn8k7e4xvePZg+pAdQ5ESqUkptGHjDuXc2P3mwPoUBQHMPrU6k
lyy0jJYxLxz2qhlGf+sPT4OqLI4OVx4aL2Vh8R6wHt6s4yv+oB7EP+xISm2P41O8aUDNahZ5dP4s
2n3yy9+o93fQ+YN1ricHTv+tPJBh1aI1zPsiGtOM9GKU2lxxic03usMefwHobjx8nPUPTwjXweCX
/55y5gcGbzBPGLwaWHPApcM3aJc8eR4+j2feMKCA9uDBOr97QB4a2UReiURjVQ+jCnoqd2KVuDem
WhgHM3gvnNCa6ruj92xZTeCH0bf0rK9AVZ+zhLnCBqp0QCf0qpJxbp+tvQ6JdQFea8X86VS1wotU
eYC+xuIV/ITZJqHfJBD1qi/88/CUEDqbCml7aJ8B1PPTs5MYl1af+Dk0++MccP/vf/0/A1C3Jifj
IJtZvhV5sfBDES1WVpYuc3iIQVxlpeh+64dPAKy//C0oLanupH14IH6VlaY7gB8+g/+Wt8kJbKFN
2E/485e/absJgKytioAb1vQE8LK2WAbQ4WySKSR81ivcaJ7m8GxuOuHrXH34AxIlhbWIGkCmfsRs
LBpycjPVh3//6/+RL/xmigd+ellfLynIxeoje/7vh4dWb3ijNm6BYImRYdlD4gu3PzSFn0aPAn2X
HaAo/oTkwNsfI28No0fcM8uODst+rKFhqM0v/30SWF1yQM7zYIIXEy0eIRd/EqZvF43QPdCluNDz
MAWJ6Jf/y/tzPE8kJ3rsR/4YLyHHIOEpCGzCy8aL55iYHr4Ng3P6AMxiEs687+F/4WQy94kAKl6l
aDuLsHkuL+aiU3U5e65ywLazHLR+/OVvSTgSiZT//tf/5qz8HKFlgu5ZQMFvyS//N8wMVC+QVH+e
E7v0UIb55W/QG+bkEuJMy9nuC/Q1Ug0bHkhSIFiOTw7OQLh6w7DJcUtPueGp6QaJh/Ic6Ct+NMsR
ZmyRctKNx4Vt8vCecilobux7E4y5VQiQY8s85T0afjl33psP5hG6g1LjLBwGESaiSdKWg3XfDGEz
7sW4+sv/Bt17wcwDASUJUPahCUHHFOQML/CiBZk0QkNOATVbQBRM6TTWWeYh2gH8ESCcwbVN5FC8
Sw6xmk1FNvTh89/js+df/uYpIs2AeBIkUfjLf0+y+cKv5Je/zdM0DFabuJJT5KUES0xajOvSFJBI
OCiqQjHeqrzy87tdKDGb0EAEWJ9G/jQ9izmpGaiDJ+MQBZcVIMTS2QrgwZ5uACJ1QcxiMDkEYU3k
cshaapVvBmJ5heb/+p+efjf2SyABjzHl/VarrfiJfrdFg698GgFZADUnRR0nwDx0GLp8GkwwZSdQ
I3iaD7UlITE90yfR8byqKzZiMvvi7kKh2RCBJVg9liSAZU9cbqEc5bFMuKtbUGC/ctSMNx/itejj
MKX5wCQ3TT2VOZsJCJvFSeVNOpVUS3S6Z2EwR5ggjIIE/+cZ/WFgRfXhOfQaULbWVHXn0P+YZf47
3cDIJPIsHg+DpFf9w3z2l4b3XYI5TR3D4ZiD6pJ66Otf/oa3bPkzNQgOcDBG8Zpu4oI6Md9jQ77L
vSquFlBzodRQqu4A5gbT4nKk9GFjHzrIZyIZlwtQ4pPEpGg+OYG94qFRFDZudFnNdqssa27Um4xH
pu9yrpz4ttSIZOGbDonc0jbUwF7EE8H+tI2Tx6oX/mRpzFlOQjoNYsx6Wy4dIa7Fc+T+IMONYbMU
WHRW2uLCGqORKW2j49DeBpcugfbxGJhOGKF1aR7caN9bsKcG8cI+nco69v/Yx2EmHman8qYwbJR0
UfJgMW+AzcitVEwg/GmI9z4usAxFxEXkN4OK/P2v/++F/69hKvf34TvHj07n7n0cnVYlYaFsGdmu
jU4/uN9DkacI78J0LQpjaVBCkUVeI9GQvbknYdSrduBf/12vutPWhi/yIC07g5tvhMf+ELPWpkV8
Dq2Vk/nE67Q9MhJ/CKd7LHJ2OyAJbc9nZYAU1srnXM4NyLYklx0NkqLiB+PCD5St70Zj50R/qw+d
633wyJ9g0sAbDZzSDa4+bqp2CwBPwr8AjVPj0kqqEJ3qw6373hmQb5AkQFQFLEVFNy1oe6W94+RY
KNwKKl3OtQ6hIJLmv//1/wTq7tTm8VbQwraqD/ejJDjFk4LApbgLifg72Hflevszsl7LpkgAx0kQ
N9WldP/cj8StdMzuTaX+g8xQSnn1fKm5mQq+uIwP7TJKm3dZmsSsX3PxlSxOouryWprUOT6SfsY6
5s3gqWu9j8/i8B0CTltMoYShWHELyheO9BNpXt+ZamMQDcm31JLNcECvRKLOpXFgFUb1nS4W5hUc
vf+ceiPvCKdFwhU438g0G7MoX+n98HuyU5xvFShAdo8fTFj3FVTdU3ses5HTNYjn8a1pHXgN8i//
AwjRzw7epDokVfYHYlcMnahcwlV1SKoaB9Hp7KxX3W63LUE2eNei1GzjcXhKafsxxSWoQCE2XzUn
Te19fFHsu3A8Qz5WrJTgYL4j58sPQPuKeaDCCWS/IwwpWy5R0CVHPH2Seukvf5v6CahqdHCAZtnz
MDmdj8vEC61/a3VOTgZN/NoACtwEFefUXhJRbclFMaf8mJPfOqasJvsK0y47ZoraqrfhYZ6kZNHM
RDcGHm5Y8zRUFq3SzeYlkvOWTQzK/PI3vPYtKNr9spUiCiC/32iIqMiVDY8VvQ+F/DPSClcB+7Pl
tUVr+1Ba46dRyaRyZZ/R1fYPU/FYtBCyuMOAdhjP8USLrhWZTNMi/kJxR9WH9E9RGdipgyScsmuE
9lBUXjjU4YLQj9K+G0bruVfldVVPxuMS88hqOl4uPV67/9K2nDtFLuCNEOsJ56teTJe5YIAXww3G
cyfVkpLIPlDSyxm8Oy3fP6Jva9PMQIwcgKA+OMP7WhpAouHf1vyttZVE5RtNep+Tda8+d8ryXTr3
wGi6fP7mMHKCg492MoSBNXOz2o0A8F0ST8ro45NgOg/dPPjgpXd/p91BLVgJSuXTxM6syW20N3aa
7W+aG/cPOxvddhv+/z+sWWKtG83tMC6b2X+Zpz/PQVUF/eR2ZncYF89tY7O7/Q38vz23w/hmTCBO
ZmVzO0zCQiIPVb8t5LX89UZjeiHyvJeNS5ZxQZyVEgD344MfywEtW7HArdPLcOLnJDhZbenZ5R18
WBT+IRhPLT+QDxDChWkhS+NcZBgFWfd0DNNKyYdz/u6DNM5Mv/LfCfFgT2biR3laHWk7Vqrz97/+
7512u3yRoF3ZYKkRutN2WvREEx+segprM/pxSC+GGxkmcTxPxTUDZfbJ7aLJyMq/giMCHM7rGx4T
ENFa7aigcCavAJkX2FqJ/ipcRNcf8lT6cFvrLRzYISh+94kO7cxe9+iQS2xbeZ4nurnpUR5ukMCc
bRn+7H3ic72sz1syBh1Ssji8iXDd25vPzhYgIu62A0TG3zdhGE0Yx0e1+CMvvBVzv7uhRbZ+4nW3
behHa+2vws4vfLjyxn4ijDew9EcrOWNFH9EHi/33bwhL6SAjAMURAIanWyovb07xii3UhIbeEFRT
pCLk9sYHOR66onu+98vf0GOObnlJJtAcu/jCP0k8CNIU9Cf2iZ2WuG94FIUEclYWrNXWg35wxs9/
ns0WLJi2LZJglATp2ROoWL7F9vCm+3GY5t3xcqNV0f7VvL86fHrFeTmqRnGRrMNcG5WPDAh7doYi
Du0yx2SH7/ktdIP7wu7DPVV0ToaqmL3dO5+T6/Pwl7+BsAfKOuxF9NzFkz2QMzVC0PL2AbG8CTpM
B2RNUj5ZnIQgTOkhGI0CCuigQQl3SiGXQn3AGQ/vLESiMtaRSYgH3i61rRB0ioq6Hw3CIEpxlH8G
jW+KhmO8cBW2UES+2idJ/BboKUwkRYRGD+4koJpQFuQAmFASFDp0fwAJeyV3FG2ak2Q+SzU/R+Fa
TuQLTUBzL3gHWwPt3bMwQhec+TuP7vFNianHkwnFeaXe/sGrzY2Wi8zhCpZT9kJKJ7b/szDNokT0
jDGFWCacucWC070yp/Cj5WKQK1M9zR/6Q1zADRWMFuAZYR2o/gjl+SxEYgDIAbgAhM6H6c0DClmA
FyRWIVphAlrmy/6fUU7HkwnE0TO6Mk67b9AZhEd8W4zHgLLb53t1WHEk1o3ghOFbkqFKCP0X3N4I
nSDygMRP4jAhbDVIPMCArEgphnsJn+lsK9koapDw7XYbmoZdgAQA1JFWoTStZRAtO2kVi+12Iz0V
X3MWcB/Hgl77RdZcmKWIDXN/x+gqGaLlLpEP5nOX0wP53CUo4rP6UATZ5izGhk+6xhBxeVdniHq8
ZbogoENUZxkBNQWM58Z4mVmMCjWR7W0vbblpD3TAuXwCPXJWZoRdgr+5WdsNqI2MUrwZtVGhjSoM
WtAa4IxZsK0XUN7HePAWCqZ4/ILqIhkyzvz0TDC5FPYYiknMtNLwlNhpqzS+dxl/BD3sV3h5FrvI
fUD874f5W7+I5+dAmk24uQxWG0CvE5gGh7MID8NSBXfZORkars4n+dVqZ/iL47v86DSQQyvfq4+p
LAlMEyOGO7dx5Vg/KFZa/4mnEZpxWATPYeKBzGpqJDzgMDIviVHQH4bIWEU0NZUDlTiZB3p89TgY
nlwaLR/yyaMhgmU5EpwfzH1pD1U0+FyLZsvJB3adg/mJOAE9mIPuh0BHOUCPYCuOZqQWHIkLMBFs
SeKCx6xdicYNvTo3Y5H2wdx3+ierHxWASgGcKlMCpUayR474FgVK6aIyDrxeprc9QW9Ku2Nachvd
PQ5PMv8ed28iLtrVmXUSomMD5n9Sa6knhXKkedA+C5ajvenhzc5zO32FzKeT7U1GKx7ek2DiR0MM
XBQGGmAM2dh1ENEBBpnDJiFxEyBxnhA3xZ2siYeXMbbKSdaCKYhdsNIknho7p3Dwe5kPKe053zuZ
h+Ohd85hrqhwpHMihRxtjMR19GGzAT6CGbhWms3rvP5YMqk3UUAa7Yz+mc45GJXpibjgk2QEVp2D
D5vOOd7YeLnSbIyQaW8UAmDLEOx1oBKkoKPlQCNbYs3OOYmCDPh1a4cl+82KvjfSRmUhz38hizdu
eWGXpM6jgdDZdFrdKunsUGaBsvtT6aGMjDNW7f2xP02DIVpxJ0AOMHnMHI3wXa/tpXpGmhzZUylu
7H6z5DclzAIUFOBkICX6GskrniQGplssmw0/zyxIkXEijFAb/uX/Rsk2FRkLQCf8H/DfNJSGG2VD
CVoem49GQfTL/0CD0IzyU/m4IMBzk0DMCBZGUxVQjm8ta0nXAYdLPM7n7wHiEUXzsSN3Sh7yiLCm
Ff2ZG3EWtjWO08AtuAms+S4AWd82O1bcW4DybGeMRku7LUWm8Bwl2HgczlQuAVB26LD8YQX1p5n3
RQ+aejiMB3OCMHC7/TEB+9vLp8NaOKzvioJ0HtK7YrGwi5e7N6Rpont03BBaLH9AVZV/IcXhXwwG
/n0yTy+7Ix+EqgZqj89in9Je8RusYr7RINi9wgu4u2sDhORwrUHEOBjuzbrthsKcrKag1gdBEIk3
aMMYvsSLt/iRGHx3be36Wk7Un4a92jwZN0CB7l1d13sPR8FscEavrgaAxwAcEFXT7lrqT4JmnISn
YbTWQKkSCFn3au0x+2w1D0GBWOuuaYEO65hed62x9vumkiibjw9efwelOmuNVqtVgz5boqX376Hz
a3wLL69hHUbziNXUIB3UzutXSTCbJ5F3MEtgwrXzR4/W1uotcSd7bf3oqwcP16rH66eNQe9h7Wrt
K+jkK38y3YX+H+Dv8Qx/PsSfp/izulaFn59vfoOvq/j653kMH66PBsf1+nXW/Wgy2zsNarO0fhWO
ap/Bv2Ika3/2QQVI13YFxvSeA060OOEn/RyN4zipPYHFbEXxRa2+3mm3201ooL4LLaUPdtqyqfTr
NQ8aorebO231XmsmXYfiUAy0OlHw/s5WQUlqAsqere26PnNF+P7nNXOeT0SseQ3mWjQdWKh24QQY
EpOePW4sPtGKT+REuMKZXmGCFRrJpDf5cqeNFc8ebGzJimc0q69ryeTRmrf2dSIbApSui8aGemNn
61C3kZz1zr7c2JLAGNLUoZEzboQbxSY0cBB9qb0No2GD/RTFvSs9KHbFPZ3E73qKlMBWgYUW1KS2
BsRnjfJptoheYYhvb42vrlj7Glulb5R0EO8s761JeWPta8R36hKWSEkaMFwxgEdrnMSNC4qXXJRe
Eyi+qHFnKewRPKCIho/xxpsadFrfTQPpEFGrwX7HgSTBJD4PavXG1jaghgYGKPstkK+auOUaSVmD
dNP6lbh/WN4m1sNvuF74b/YVyBu00eJ8YeIlJjIVZGM3/6pHZd+/XwNhHfMBsklr7TrANKPUfr5l
1Z/ejqvg7hCv/Ag817drfd5n8cWPYXBRw0vg61dqmX/GkIWDgI3be+Nxbe3IspwdA8hHcbLvAxF9
13soEACN3OLmv9oa5/Faa7xT/WP1V2R36/Wox/puSZd0/XPW7417zDo7g8JxcinpKWWDqhHzWgPy
+Pna11QOVxd/QL015GRrdTolgV814xv2wd/wuK5m4BMx1Mc4wBrZcYmqskUXasZkjVlTJBbztRK5
UyVgfLBphmvv36tXxPSAKZjvYkD7YdYS2hfMliTiZmUUuVw78YdruVGTJ4octShZu+Ihd+XQG/Fo
JF7wj7WG7Ki7BkJhKsK51hpiJt21X/4vUAqiMBH8Hfn5WqZC4VuaC/DWJAEZEupe149oGMdixrBZ
QGc3RszCymM/GdbSBhryoN8eSQGSfKHC0jtKW1MR/9RIWzPpLQK/QRo9O25xSvLat3E8Dvyo3gKx
OqqtoYeIIrgsk/agxjmoIDjTr75KCb+AVJXnhJF3tHBePKZoXBUIWvXhy/l5EmbiIZA2x9HJL39l
6En6p9bQNFLLAw9bYzTuy83rFECtdZRNWyQY4ujkib2ecRWotKs0Yhth8iP+p1tUCNHuEf23sAjh
8SP+p7tGKV7XYDh1pfxIKDJdRL5QNGWpM0pOMvMBj+gw1qd4RsBBTDibrGWtFLaV5vOOklmvEHxy
nNrOkl81ZvZ17TOBu48YzZC7maPRsT4BRhck8qCzJjEdFJYeNa1uRkIGqZ8/AgXNeDEUB7lnWkt7
D81txNtHbgJms7n0VbmmUpCHAxCituruVtHqqze6kNfou0an/SfAy1txNID+3vaQsysmdqLIvqiL
bw0pV7rx/DCbjGsXiryt2cqnupCzIIefMFi6Lf3ZTZty+YVwfdHCW/n64uSk7sRatq8MlSeUyNE1
C8rOFhYNl5MP3Gy0nEWgbLBcC8pz0T6qbMkwBdUFqTVK4OsehtmXbbBlZkGJCG42CUopsNQcqKRz
CpgcYPGuFOe9PwT+eHaGKCZkf0C4noV9uK+ssHJjV2EdY+8VlxKSOp439LJWde83FNPxX11Qd5Cu
C0GcRGFDci8wQ+UpnGxEsk6UVntiJei87FGtpj/2UVMAoqzcKQjiyHy/NpeRS/sz9Vl/XweiuQtE
osadhkMvHnlHa3ocPgh5Zn65tWO5QCCTfkGWkWBsSNf4G9/lhU0kO2sNITLU6NaC+nUOH/BoXyBD
ZCDDyjTnSSFNWHYzRAytdD5Ab46y7WDkwPuQPSujBpYdadTyuUZ/gKGs2QYspZRa1r4PGSw5mS47
Uh3hI52lu8ep5aXQyAdub93ftHz/vygtadEA2/11SQIQ3QYBiFwEIDIIgImSuY0dLd7YyvNW39Uq
JeLH3NnwPYFmMLmtZrJD1wIY2DnrZWi+W/vqq/MWBxE/7HU2Hp0rIamzAZOydBmmF+KQjFXTuZwD
2qN781YoU7O+f082W1C/wuE4WLtugMqBi+7I8LpWb/DS4Pd8vlb4PODDXmhf/AJSzOl91xqsUfew
XV5TnB2dX6Juar5O5lGEs97F+9zzUEVb+FpjzuU/g/JKkQI4fcYd1amusrXwy/fvnZXev//sSI1z
bRicrx23KIh1CDKxmAnp687B14XR20CJtadWelp/RucYeL4nz1Dx7BQNNUIBu851IMGwXA+UANc7
D308U9H7UCkRWt4z6SY7n2lHLkmreAxE4oNh4TwzXmIc/MiEsKCQUHuoF6VnwRB25iO5MYMLD229
uQK/RbNvHVab0l8GwoBdJztd0TD5MpkcItGuX23kAMlf/oZpZeTQlRmRh62/04fk6GKeDSRDtkdr
hu9IdhbdQDdRTEMCn9T2bIHOWprwOL/vecvijmcVjndqb76rf6bTEihj03otgzZud06LnX0QebLh
ExlD1HtMgQ0vKTd19pYSWJeThV0nrXLzl7Vdal8jCP5wKKhBXXwzVpjMV9oiTPxo7o8BHdzsiy1e
y3Or59BcAKMSUDL75tzmE1EEoWV+/zF3qu11AbsARKzT9cWxN7Oxc+NQXXeR1Cxkgb6LtWlTjiQ2
92lvidzfFiiMQ383RCQSoCERKOyjtdcyzSzSxB/2957gCS9sujndkDw4AyTBgsDIkUh29fLkF6Bp
tiJtPOMUkdQcwHPdP9n/kTd0AchFynmQaTQenTHOYZ8LAFk6ONz79tk+LZOjNfeaZPTg1rBRpyp4
UVIchbTDoGNr8kAZXChLbpMYicFeMph7X28nj8OLQLgQdlDs7//P/1euHN46hNYNVQjaYpxwIggd
dLinRAsimsuGVj6rbDm1velaWRwJRaEYjE3GpegczixXwNoIQQQq94ma1a/yRM0qkiOJ4mBKUMXr
ayf2zaf9WdxHEl2IfnyQsDz6/fJXwrwl9/63CsMExsL+zq6BQvcl+f4T7mRcT6KV2moq9pxZEPRC
tHKLKEBpu0FJw5J0uFcIrd43JdFeOJnGIJ/RFnDuHA6TlNccSLoiYpcdq1IrXBYdPGsEZJLKYPc+
VYPAjtCei8mVvw9nP8xPpOFG+AcpRyLh1ob2XhB9/PQyGnhKAMITNCH+SH0n6fkXfkhuG7W1dfjv
OssmvOGSltBoer2tdqd+JTNM4yaDtmq6wPlZ0orfiqMvQ5aqcQ9JC903amgltoal3b+hxiXUrNzV
HGt03MxHyLOIbN2NNfsaEraku1QwW0WYIaxPlTsdw5Y4JN5UWA6idRrcWuMKFvssHsIOfXlwuNbA
C9+6a1fXa9cEQgbLFR//01GMNV4d18zJ8fGABHEZSHfHwYxUqMl0lvbaQmqdxnhOEcxkDoUawR0N
+Vey7Ne9zi63peMGeWNowvGjTCvUhCXZBmrcsGxAdRPVE3btmsz1dYMcAmDqg7NaAJw2P9/ZWRJf
eIFuB+BhsDsxGz4knsx7+kDR6QcHX3OI0nXF3uVZBO5Ap0DlYs4m01WHgmLvUjMz/7SPR9bv39eQ
s9Zs1godrNWNUxIetTjj4InN6QB7qQksoNdqjDwWi+qKI17LN4MxgFywa6S/AzEFvMMFb4gOtDfC
P0x7ww6x2Qt1NuxPe1fUoGxGVhZVrhcfU2met/opFdDUh1eGdUnyeOmksIbXu8I/QgmWSt15D0Z1
BDXlWdZcTf6YDva/+uocUV7NxegEdavz+rUOP/Kq0/VHNXsDSekbeTDhtZLshABECOCRon1m0pJO
dpKYZmok1oSpuzU80Zx07oNn3aWPz+rppXLqU+9kj/yiQGUWOrExl6VnKAb1/v1nczmtJQ1uZdqx
CRkRS2FReVELhMo302mQPIalrgGbzfFj3vQ5aiDdn/JBFFY/zr1s1WQKZlUE8NNrUD/zZM6CInvT
wray2kVngzx3k9dLDchj2JBUHtnAk0E4divPlNu3yEugiWYispzFMi3Op2U3LgwmBUqcu+wyQpse
xZObEBKxws1iwU96ny9Znn3mc6AqsCtysm4ka75905cyOWrWRh8d/c2ABYyShvfs8A1ioFLQPGh1
jCmJPJm/KAd7duE2JmYqQXZ5iWNLV8CtXQg4Ib0sWpvSHtzLUz6o/KyLl9M1Zb00Uyqkpb1cRRE9
sCZ2qk5yiThGOtLn75DmHUDlihBe3CVtRCMYOACEK9HCRDTz19quxdMlKxT/KA6peNwn2rh6TI/d
jpOY5bbJKvRLxAGh3kznDEMQQzBlBWgxiCZ/4YsH7TCWtaU2vbpL10NpOE78UOT0CVm5mEznQSsj
jR6F5Kd+GNjhGXo094bazhiwvDBqRCM6+e2/zO5cjKds7yjF08KImTXeGkqsufo0OPbLX2W4VJAs
hWPGiRGsBt1QkR0dxXMzlQkIbXjB0y9/WxYV6aBCnJ54EWaBQvfyX/42nIczTiSGbFqchC2JfoTe
WkwYB5RR6z6hNTPtJPjl/4PWcJG1BTod+xRom2LELXAhG8foCEwiWkIndElC5uQm+pkCWp6ryDDg
ZZEIKUdchR59TPaB2azCNItgEtj0y9+WwFGLthcda2VHjBaZyxE2169PRez21fHmUmgoQ1Bt45Ie
kro09bNEknNACpTpE3FEQD0tj2qJvAoAMTdAbBsDcWO8RjdBQCcQdWCLQAUkhArLI8B6IntJcDMK
VXj4+9VXhkqTRwWT45mM71NhgHX+swQSuMJEV1h03HEI9yQ4p+RHkTcGYgxr9aM/DofC3jVHOjAd
xyHzn+zM9EbSLnC7SRhxgip1uW9KNAa0tXBMqTsCInSpH+GDCiRVZDonHt8urhQiRwm5+FQoojOf
1bmVXLub0gWpobiCwJfHB5fvBC4lSjbeJCbrjncQUiixEptQkPUT/5f/76whOKAKbaXUG6D32JIS
Jk3CawY0qfeWMGWRn4QbfUStD0EfOq34AFnnfyOXjJXxBoWReH4zhiJzHPiUQMfHQGxk+gCrwLFz
nUijO4twrADeRIrB5pSu+TTV/YGmKEMPMehT9kzJw1icwcZvT67IvHoMnwDjXHApPkP/LIsDLGPf
HAkOiQLn5VEnGjw3z63kSe4t8JilVr7gyJMJMbl6LDwbB6nVtzw/hPQbpJIdEfnqKm8S1bzzHHL5
Fm+IZ79qKfUVJ+FbngHpFVw5e5aWKoUYqiyMQXQeXyKcvb3MKxDE1gm6H7N2McylWlmNAWgm7hgA
/SZnCyo4YKITvXmBn6Rp2HaZxJWJXhic4IUKwe+1b26x35U25J7LhFxyfpDD07wLXO64Fs/2uIhg
JTVxEthr09mVeHrY+6Zt+thRi9nI8ex2N/+dIZTQndRry57jaiwNTTponN4VqEI7GBTUKMuoK5OT
6up8a80xe7Vz+YwUHVZeJTFKqLUEw65U3HPS2ECnzDodGzsOVPPTdKy0q3+ZC8A8jlWnJeJklg5s
Xe6oZaB1dSeOqYkTNQp5REOSfz8DIdqh5iTAR9JPStDVlsFoU0PMSm0v1BsOmM/VC0SbRiHw8qJH
4hQ9FI0xZpI/IbeEhK++Sj/LrBTiyfRaXnW+onvtAL0cswo2mU5SqMhS+8yRiUlpHn//638rskK7
t5ZwvSomJ1938rTHcLv/cBrNWQQcNKrkQM7wT3EdIhTSNHXK6yiRsYEsv8dyVKN8cYvKWPwj71Oz
D0w4ZF8ap2P0UghDjSh/VMHlHR7+SzjbiJUvdbdBL5hh7+qa2hv2TCeZbMtk3kpXt8F+hi0OfM55
bBXkx1orIVpRxsDWGlrD+6RUSTrkXJOrVqs1byji1pXH6ExdZbqR7sqjvb52uyANbW7h4sJrIrnH
bn6X1/8xNCw7r9EOaCgtbGa+YOuDMvyTpWGhpOCaIcke48srlyNULsqchkupcji0nD3vKLQcRiZU
GHs6oMikLelKzSXfTHFz2wXn9Ja9KbO8PC1+3efjppS2NeZcpkgDq4m0hV9aMr/Y8JFMUZGlprCr
azoKnt+GA/SwcLTzFtrA3aD6dzpKiIqY7+FrqPC1eMb8Espni1+hFxYoNYNAUOsLqCvCU7VYYOck
HdG1jirOiV1kQoCADE/N+CAgJbIyoEOY1rxTRSqL9z4TXivF4dR/lkmRMKMGRvLJSMhFs4+02evl
nVOPiqYeLZw63cLgnHdhiKon3sNmIZTDtHnB5DnoMuQiYOIMfwRRD7/2lSTQn5xAQ8/Db71xeAKk
RGvoSZi+LWpmCN/6oyQI+qcnFKyOOKd/m8Ww9/nj91rj7pj1XUfoshQwyP1VHcCqyNJi5e3EEXDq
2GycMURst5OlTAMyQZSjNbp9QdEBfhLrrKXdMNOCPYtPUW9ypUDDBZZ+iyo8YJYWhLzlaCilDsK8
9yFGBwi3DQRklgSdHTU+E4UeiahRKGxAovQ2BpFYX1wJpQyiLRlqLA/VtRZFd5Sw413vYa4Dioo2
4E95+QFKWmS5hNu71izVkprkqqnkNFzznUzSUVJlHIDK5sny9KQlVcneFNUX0kVWIZdHTABHy0sy
aKWDBJjmYTztyd8/BOHp2czpuM5poa6U4qWlPnz//jNrjaWYnyvKkoLQqhksAj9EvhUYoUyBhOLm
Ln9MC4QJPUl+uRiLjTySPQKUIrwo+c3rp49BAIkjzPGWrdJX43ASznrb7fZN3fCvSoctpEkU+mAb
z5MsMk6mvDNF511tdw1bApffvz86rpeCJysrtxnm+gPCKDYQkG9kX37ufgO8zWAtE55ya8heqg4s
OQXUsiII6KWKHZAv3HBZc+hBSl5kXahsiTHD1To179ZS/svByxctDlgPR5e1K5lBvitHJVPUSxy8
rhsxBOWDf0qZNUehj9fzhNE5HvQy55EOeM4+cNY8kRPQxnImoExcRmvayThE42mpWJtfFDSQ1a+K
oAVfy5U6G9k1qk+3WDGlqZ0m8XzaSOejUfguS6dGb5Whh5EWg6mHtUnv4aTFxWFfiXpa2wSdQ4Bw
7Vy0SqkaRcOYfADz2b1/j7/msD1GeGsSiyhdmVS0/jXXLEpeQ+nsaIiKW/GZRC8/Mykjrg+k+3GD
xcKyslwCipJ4WFaSCgjmKPMmXWmSaXZPlnWeYN9xJS7OMu4JKCojkqSpq1tKC4uk5cyD9WvTLMBo
N6cZOUoW5BITmHJGctij0sRizqI2qyuQIZ4F2o16mZsW8oMkkNGRSJrlnU/BO3TRIId3eSEQH3k6
r9SyKDlwVgZKS1w3hREyjWFvSkEP9AD7Cx7lLqNXqAv2hijmDUP18mzQ24MOL1thSv/WGLceyZYf
kZaS1h/xe/ma3wr63203hnYzhHhaK0P/Ehqht6oNfKea2P0VYiXjCACxxQFAR/hz7M8a9G8cqcSH
mE/zM41gSHmo4a3V37+ftlKA1gCFD/6hbkOVYUkSQYx0Q2qN9ShaOwfYPxD9CWCsLFq3aGhfiu6Z
wFzvv/wt8VFOMa+bEEPLCPWwhYbjgMv2Bw2A2P/v8Vpdz3tr9MFrhyZZZJ1evrlREIzT/jh8m2tt
4UQLr82Qmyp1Tgb3XEu7kvv9e3qDd8PIiK3y2ZzNJ+GQfK3y0xHfLvvTwQym8+UHTwaPgM/DtHA2
Z4PMRjEckDViwfCnCV/N5Bg9fcKFPZv6MPqzV75j/AXJ4l6Iqx5NZsvheS6uiEaJdf4seCI/EEu0
7o28fcqj5QJbmRlqI/9PwghVirQP5IQMFIMRCjtSarGkqTQ8ASPKfmOefiAIyDzxH2oAE1hFPVlC
ZZ3aySxbvwo8EdwCRq2y8y7DbLiamp0wlRj2t0KeJKH9K2VJuDYKSHwFJ9q3cDnFPB/xA1ps/N5D
QTHSZNDzHwnAPRLMXnsRDh3QdGYQNgYgUuUZtNNv0SpDewfotQ8PSWBSz4LcmjBGY/3EgvjaWszS
ei6/ZmaZ6RbZvw7kTmTl0sPrCtCZN5UIoV1IK3eh6idPlOUVrrWhnlj3CC9yGEpzvaW6NfgjAs/6
cow7TrtnNZc2V6yqTMY7ISsc2Z1T+0pWuRyc+MHCU1FmFk+RL4pcxy16fP9eapQFpjJZmZfr3+MD
T9b/OdaN9vbaTRz7SCC2GiTgkt0NWm/kEC3jw0TSwQZlZd/gNqENxAeGim6s65aaROX11tnlwZmr
jZtQB677rN1YQmx7KE/FkLj1hnZaLuM265L8i4A6aMB+VGwPXyEXo6sxMoCrQBdpET+Lk5SdI2WO
Z3mTsG3EeSEPrvTBqtOsTALk1B9ku8sSpIDG5k/xFSHJbt7SoHaVfvAgvuCWkq+1jek0xXIW/swU
q905YxpetQ+64VWY5nI3irOoBV/reTuccQvqYlscXxlwQ+OpcT6v7nfXYy5TPO82j89Dupw7k1Zw
5deso3MCnJ0OxbRz6iBj3wwHSIqMbWzCKwRKKnDOBRZpH1wQYutPp2VBtcKeV1Iid6S10EPftSh0
BayxIsULgtOcCdnQCEjOz9caqz3ZPDgc83W6VIrDfTttCz8Ll8IW+gwcIU6KPVurN/AJN6n4mWWi
b+juhcfy0PDCBzoy7CkUxytv1Z1Ga58DjNA9SWZxP8qyua4pQ+AaKz+U6hW2UEOltYefdEcHvuGb
fPU0oNxz/RH/29VadpOQXE59B7aqBPi7dnohM/l+z4ar+oKSwa6dxN85HgXywuEoKyOytlPHoKSr
gXV2wmMVtXsXmvVqPxL3hcjEVr2LVsDvCLdgDWfzoTqRosTe/Aovq2L0A25ul5HvskKMDchbjHL8
WqSsEWV99EzU+otOd4lSY44B6e2qFRAf+jP+QhucjVHPw2hO6S1FWbpECaT0aFi7UJ73ocgXRHc6
ofcKmQ5LqwpXCLsm2QtLK7KDhFGPV+wtHbW/DS6l9PDWeZJ+0QIs6EOxPmMA8lklPZDzPdVcUnZw
t/YYg2jkC3Sf6vIr/ySl8NH67jnH7wUSXwUncKE0041CfCZDwQJkjtzIjFV7kVRx82gc6WiMRV4J
pVOtTKTpoVQCRkSOKgyKF1qdWkQ+eUqj/ndMD6Q1ROmCJP6SowqpX6lWhBWyVC/0GD1KjHYG/MYo
BJM9jc1S4pXRYeAng7Onkd4jveqT0U6VexKjGU8f2JDf6IX23xFFzZcN+EPfUec7YCBayRE86p8P
Y+3jLNY/PdP3e0T73QRlMvv20oBkMuuf4OyVQrI3U8VfgCrBXraqQiRe6a0+99/JbPVayYn/ri9N
DbKkzCdWsrExH4FJCigfu5tgRTmCJTLxavj2HJANMD378DtBGWrZ7qOtJbdeFhghWpAZyoTaX7QH
8BIfYrWP1r7HBmGzU975V091Jci9J5jN4lDpFFLucjmCXkGfDfJulcsQI99okA0iBkEwaxP0WPgv
V5HRLPAi7an2s7EfHa2B7ktWK/T6QfngEK8mV8/HjaM13g7wibfK2vFxd6l6wTns7dkZB0TtZw/H
x7s0wozY0vhIsa8dnTfGx3VU7+NpdpKL10Gds/FojKoufzMdUjgtGK6xaC+NJwE2iM3hOa+EVX03
A1CPKjySn7q1PJC++koBGcMdsnk8kpDp6pUkPTSriZKP9PpdC4YqVQ1TqbBgyfAOttMAQOePUfCL
kzEKgBH7+zbWTuYptoZLMgsGZ1EMct8lPNBFs6jgU3ZJkAPR85IEwkEYRAMUwdkAtwbLu2Y2ZNfN
uhdV9FZUw1r3x7vmAXkBiXaQ7gxJMrAQppyX4EjtHC8MjJnqFOALZg7OWswy4stbh4q4iCiwSxcQ
FhVyrJsCGl7TIOyRCKiCbalT6IbxhFsL0+Se+wzv7DdvzOVqXmo1L+nLNJ7Oxz6pBg394dhaPGQr
PSeLyTGebPFoqh+4w91sjVu297o21voj7aFrAMS44ROvX/guDMZ48y8dDaBaHQ7rhXc0fEaFcgkh
Ta6zLG3PBMleJqY9knJmqguarSPZ2vGjRzW9tIZK8udXXzma01oz5ehIG3uhLH0bEnRObl772mLA
X6+5ZGlXsUy+ltfETEOYBBXI+fxhI8Ck8w0519EUK27Op8UHoPc9mQ3Q4p+08x20oCH4Se8zehar
dcr8pEfvvvpKtik5dcZkeqJ6VkZjQLaAL206OsSoByHjeOdbmZjjnW9kIiy5R7iqwywfWVPt1sTo
M/6pDyqnKoBo+Yys/2IsG+12d7vdNor9EOYyOqpOYtjvp/4sRovS//qfHlQHDpv4gxnmQ0o9aH6t
K2bJRCcKxoUFzSLbjiK7OiXRVRp6o9azni8ntBpRDoD2/v0pG3bzRQXDyco6CqF6IApk8C1uUypC
rioMS0cloenk6jiKmrrRMjVQM1phAofxKrMFZrDSTKV6JCqJdi0l0kVzBG7RvdSpVDY1bUrWyShn
TVRhjJv6p8FB+JdA3K8ntSzPIK8weqCvnb//9X/vAE4CaqbBGJUa0AnVVahS6EBsZOVD0gbAn6++
khc5uRXx1iwJJ7Us6CNTwdU1RFnLDjnOVQqPINRT3aAlPwTjqXnkLslO13uAztcPhVngwTo9UXKI
UQP97gaigDAJyALBTL4Xg5IfUlgnD224rbVdeau0RIMFY2KqyIuvBvaz6hGgrROfXVEgjESJhngh
1Wz1GtlPiiMGoIvxSbJjjJJwcKkxGtoZDPUb1DJ++RtLv9qdEZSyEOgG5lic+pepGEvDk2PEUf1c
MiZtQy+5oJlmCOOSG6Qh8BQHQAQjyIbC41sAniU7t+EieqW1QxeAyRT0Kkqgex4MPIFS6xKFoDOX
zKcbANJz2inaBWjnrXQ6Dmc1kLLrMqTkndxeuSuW+eDb9GwOh0/TGFtEu9+5rCrvV8OTOvH7sxfz
yUmQtEKQ4F7UKDZ56idpUFOV6u/fr//XPw6vtq6b8N8N8d8v1lvo/5EVs/s/vIi1GakxYGNHe83/
8Jt/OV6mGWmMQUGajhjrVxgFHL/l88ajI1O+ahiP4v66xlEmZzXUT/OjpGUN/cksIulZQ3+yikhq
1jAezUIstTSy39ZIJANoGI9mIWk+bOhPZhHL0NhwvDQrkJWxoX6aHw9j8ekwNj+QhbGhftpQJUWs
oT2YBZRFsWE8Wgun2RMb8o1ZxDYkNoy3ZlmW/UURfjALWMZFMW9+EiWPVXr62pHfOEGdki5IYGkA
3qgbG4WlvFdkTG/cXFcgy3jPZTYXu6khaFWvlGHLXAkUk+QwNUhpGkgJ9SgvYqQKddiJIhilVobd
DSqNGpspDIeT+YRNLS6zmqW1fPXVZzSCpTtdey0TWupcluL6dMacH0BmonMoRV99pWi2AHD94UY7
N6gSktJY22grRiKgwMPKszxxeKOIqvuAo57rvoRcYdjPMCDuTUldNjygqTNckXjunfO5tqtP/TQh
36GTEoiuBENe2BlyLcehR74zJ7FqrCEDWz8L0G3m6cFL7/5Ou6NSQhf0k52e5HvJUb1lesgjsub+
Fl/g+VlwAZg3wwP6zBMc2h6wPgC/wgkmzj7W7ifsFZzBrCQqkA0MSnwmRoIOBLV3dXbL8Ye5+ZeS
58baj/44wAQKXU+bR8MT02h4PIv6tbwj5F2PpY1a8UERr5ESSpCCn0IFqAuiA/z3QYf+eQg6TG60
JXxCjhVDE/nSPEDKDuY+6lAQpryrgvmFNcyCU6qCocpG6phkkn8+2M6NdRmGhQmaIiIN295E9i0v
AmZ2ZI3UfSxWMFDRBIxT/ELYip8Pd/LgXcwWi6G8A+ROT7T/DzJkovbBDBhYSfYBHgy7oK3R2pAo
lCAaxSZIPJjEdFtE5TkxIFN7Jhoo38Iw4rd1ww/quziZzMeUapn4FSscQECJsCZJeCoyWg3O/Mk0
VZk6U+UIBaKyJlPjgL+Nh5e/CkulEk/E60elYgoeiogpXYlF7C4UqtS5G82ji/9hsam7hNjUlQqm
UOq6Nc3i9sjNh0UTlMrgQt5GA0NvSIWwS5aUz2rKsiJFiEcFJ0VYWbkbdGsOeYSPczU5SbVley5g
W8K/oOto6JHbkSFbgIblpFDWiNvRQWsL3RgK5mOCWJcEtPqzeKnaGX/X6qI8slRtXeQpXFvhNbHq
4hinVOaxU0MaU4TduYj5ZzPS3Su6i9lsQ/Km7nK87rc77YblW9Fdivc0BB3ullHY9+9xvnl/V7QN
CDcnJbpJi0DddGUSPseyhrqynVPAWfRYnUoAeXU7ah+ieWfta6pNGQ1UFjxXEgEsvdhnmTyyKORs
mfQBGanGLAEFiRuM5AGlM9Lygslk0gansSYssyu6spSNABJRmKbw27hiBGW89LRXy4KQ+tTc+/ec
JAyaffk7ESxopv4xU/6gZ/woTAjTZmN187jxsqsd9xbOGUZjpTugWRInFTe0w8ZJT1fLeJD658Fq
SClr6GkqytFPS+MfiOztIv5vlvgR3XhNxkxx3bMrvZ+4TEJlL1kCN4W34K8QOx8LWY1hQAuIqfRE
Wnt3Nj3DFzxPenqaf13hOpj9at1ZeEUjmoSpurcXRTe1S3ANB0ZLqT8/D079BK8v93a1QMkkGGDO
Gdh4hd7jTn/xY7qNU6Wr5cgLnlNjc7u9bKo6zYgVDhuUWvDpMO/lIH3ghVTMIqws/YX6ZWVf0fqR
4nTWiUxgmO+MnPZX6Um0JKVF+85D28W22LSsPLQb6mdmKcx8sxvZ7+yzL3UE37IwjtlMMjaMpYmt
W80McyOUsNyuG/JFVsJ0rm6I5+y74ULd4McPMWcWebmr3KvkA5TzcgdJaO0RsntNfrALIXaL7D62
A7yzul3K1PQwVlWlc8n04O9AuZ5RIGsdOdTsQfObNv14+E3b1PkK8aCx9kw8K/0Ocx8FHjSFm/4b
keBJGwrMq3gocYRDiaMHzc79Nv16CD+swRTjHQxHvrDHA83ggOAfa0Sf1YwABqfezPqxv1A3duJ8
I/OocerAYhsK65wVo+DqJbeBcBXIvCjaLzGSJB/LQFK+gRcaRmD71XjMR0gSw+GxF4+8o4+97aUV
4DwDEdLeMqCcAzjOH3SM2fOQM3NVp53Zq66XMm58qF1DYK8wbTjMBEXEqiE3dPeDaNVp1sYNKVbD
iNfpFsT1SAuFplT5xQoVq7nuLdWwY3S00blDfEgHtMJztErO2B6qY0bmaFVcQT16L5RaqLt1X7SA
WYK6nTI9tGB752X40yAe6A57P/c0gLtsQrQZflZRiuTNCHQnDOaC6qDzux+mYUKX5JyHmCA/nsOD
N8ZCsNVRtAuSwVmQ05qEmiAGpbSEvFT/WjaxWKCX4Wyi0eUy1rFp7Ocl0et6KdHf2PLf//I3HA7G
iIcqmnNFHTMFfV5brdecyhvBNdb9N9Z2QY3kPN8yLZyUcd41wrpK+RD31M3kgwSAFuyPSWeqCUc+
aDkWOzmEX7qg+a5Fii31DLpBEA0fn4UgMMUIGHwZR3gPzmnQq0F/03Dw9pkYdDa0I4G9WJyx9Zig
pwpkKUwLGmgf20n9GC2BWsbjOQJXlBQNoTEavsEbf4bqdv2a3GFMzOa4f1VubVkFwhjjO9aQ32kX
nedI7DsV9OgOeHyXBTwWBjvKdVgyeA5NMFk8qK7Dq7eFtiVRQtfkxU5bYEsa6ergbViT5AZf2qBk
8MhltfZFk1vKrCSA9iFGpaFyD3wEAoLUllF9JjkSBMz/9T8tHZuTmKx1a2svYWvKMWQWKCOX2NeU
/Ut+MvNxU44rBDPnNF1u1QtsT3IYH2Z+ugn2avVWx95PY4SyQrB/tUhtWoVWM0T5LiPUwkVY1g4l
0cs0RT0usj0FbJlawfhkpi64LfuTheLMNGUm25qdOzWTUO1kt3jAOBWnlfY3RAH8LLjgg86GNEtq
JQutTpR8iIux8mQtUGfD9GxiTWjNKeeZ0ysR957HQ3VT3ZLpieUgl5P3pA6gMhWLFwjH7CVC7XrZ
vSVr3WhjPY/pvli6F5T21YQg4OQYxq4qwIfMxrvUlzID5yIEWNtdNHlzdmpm9p1czkKr7R9j+90w
X0xZGh2RSKA48cl1RcnUpFIcBExh9oCMrLUi/9w7oix2mBzteC2TzE96D09QaAZG85ZkZpXL5IQS
58DkW1inXt8t6YDbPo1Xbfk0rmcZxOW2VJXo7a4jzTZQiv1zGAkiDgZwUq6JYXwBYnQAWgYa21rw
Bu0A+xHd7iMSmV+bKWa0jkSqDUshVCXE+123TKqKad923QKAKqp923WcohpNvhCXjNinWkZjL7Sb
SDSfkjysmBiuNWpCI3MEw9eLo/hdAfvqeE24qyzo82ZtZz4q+ebDaIomwBu27uYOCrjmZ64QDN5y
qiBHafUNixrXq+UKu2/K3C24Bk1VMxq1S2PU8VgfEN7aqXVScKnnksXdq4s1tb0nbs7s9ey60l/M
vh4Mb5RTd7nV7SHQvlXUZ5XNnw78KV0aeNNe7YssijFbXqhR383ysOGzg6pxwV13vjajHH7YPbJN
qQ3jeEQ7nFCnAcJgnzOR52zbtinbsA9mZ1ThsPeQDdWle89tDQASf2Q4jTVyHuSW57QZ02GFZ5SF
V2j+ycqNWHOQNsIiLA/bzH/V8mh1+40aDomWI86N4aZRJgCauD0C+KQcQo0InDi0sVOpoQ8wwkDm
SUOjvCGU7OoJzq6vG5ttvAIo337xZbvQs3a9Lp9RFd2DmxuOWXZ/7E9TOhawVF88e/jlb4N4jkdY
Xet2tVp2lWNTG0l9nW4zum50ymY09fF6bLcUI0UYyh3LBTEnZ1o9Fh7m+OqRc3riyul6PbtS57qx
fZsDwRerDoQTSjJEYCSVB+vsLv7wwTrqJfDP2Wwyfri2tlb5zQ3+Wutn85P1NBmsqzvk+/hGabbp
+m8+9A8GvnFvexv/xT/73/zvztbmvXu/8bZ/8wn+5oh8nvebf9G/Jda/38cj9n6/Nb288fq3d7a2
itd/q2Ot/852u/Mbr323/h/9r1qtvsKFfwILT3cGZTattAUfK7+5+/sX3/8noOHfeO8vs/83O5vW
/t/e2d652/+faP8fnPkJ5SWXtuxxOAoGl5izHmUStMwSJahg1IHX74/mdO7Tp2PoZOb5URTPSKxL
RZnZ5RQTDojvoL3PYmi9UqmQtOOpQ6ia/FTvVjz4GwYjj2RBPNId1b3mQ+9FHAVdr9VqVbQS8dRV
4G4zf5z9jwb5PqYNDpKbkYGF/H/H5v/3Nnbu9v+n2v/oetbk9fVO/MHbINKJASXIPovHQ1j9O3ng
X3H/o2HkI/L/zXvtexs2/7+3uXW3/z+V/C+s683peH56SmmIKCYjowEj+F+mJdDHHzsrygRoMEKv
Q1lCPlfEMx5/yd/j+PQUBAj5ODtLArr1Qb3Aeg5J4/APr/b7j3/Yf/y7py++b3h70SWXmifjcXjS
oogHWfaHw8NXdBrZ8N68fka/jMKUykcWhnd8K7FRRFhl9RZfB8MwAaD94EfDcQBtC4tiwzuZh+Nh
H88JgkSApNXiQxvZwAsyoOIb+Z2uFBc3yKSyGI+kLy+pEckw5PXt4ZhuseOPlUo4MqHCgpZonvPL
8pVQahb0jm6014vy5ebjEC8RlSXnJ3iRx2N6CcLds5ffez25dq3TAC/lRrfnPrnl9vv1yov9nw72
Xj3tv3758hCKVs9ms2naXV8XAb2tODldP9+oVr7HgrlSFM7ZCmM6fz3fqip5EuFGC1h7PY8QN+hB
yJQo4PpROAv/AjKuuFmK8d1D7qZdDzcC+AESM16Lpvuvgz/DcsplTWuORdaE10R86QvUIDG1gW6u
DW80xfQOw6CBTlkNyosVJJj7K7gAfKp3Pe9zL4p/9rve3osX7XaHGsU/4ZKNgq4+LurgNSzTM0wP
EyTZdIMk9McwXxWh7g388TiFTTn03gbB1POlk4X38zwMZt4UasRD7ySYXQRBBPstmDAU5LykCUjM
B2pnPsneCDBtlsniatxYtqUXhcWksjX9Zd0s3x/HQGJ62Z5vPYMXNbtUFLyb9UUmDijdbrWzwSbz
SIwzJic1WFuGLhALUBXC0yhOgqMobgKywJthEyodq/YvwtmZNpRsOtz82L+E/hyDaBJVak1iIHxx
FA60IeMf7EOu/NBrm23iH1VNx7A2NSpl1sX4+VwV6covp2j1J3we8vU+F+l7vkuCgLOqpB4smyeJ
GbQH06ObNb3fMbKkEyjnTfwENjYikaPNSeDj/ZNMLUQ8AjlMxeT9t47n2plMIfBxQFwCKGOSzlq5
Rp0LbcPY+zqPZrBJ+oKC7B3u9589ff70cP81VHZsmlqn1WnXs231rZ/S4Q0TNYaeishFMoYEieAn
3xbvEibuXY2sN7zfNjzpIA56bOK9pz0DjeI/RXtIcImeaNHaCjLoKAb5PcGr53qyC6sg8x74rLOi
mk3h6tp8RDuZsg1DzsYGKF0wghBDTGfWVPAPSqndY9ci56qphsboWt1dvBG0Nhk+KgxrFI6DFpKR
Ph5N1YhvYtbe6nw2at6v1nM9Uq/vBsF05r08ICbi4bWb7waO7edjNFbGeUZVjNLCsWCv3jwS7HgM
FOeqaHDX1TrvGOhCBysCD1GkUt4jt2ug57UnhwFrwPfQ1W1GgpiRrTHBh3yPFK/CPdKVkgut+zAc
zI4AWiRTHWfjyi2IRj0Zv1r4Ty2RUpAMK9MhYsWk1BHmSYA5M+31xz889IL1lgVofXWk4eVT0p1z
AZcEJTbiXUHtFvJt52KJ7qQE6e4NaCOQwp4HIpE/myU1KNHwqvy62uCtXzq+HBAKBhwBA4+Ttx4J
uoB3yN5q3E+9JcUwRDAxJApeWJtHbyP0uriuGv0Uz1ZPXPQh8JUsBxd+6EGLOoSLcSzxLwCYiLIt
vooPUSKHATUqgF6boLTInJUg6wPbgCftXf3DpoBbCkYvvB097LBkV4cpufxEA1gX/6JBG6v+YT37
EYZNvZvSNYtqX+S3PfRnSMxAKJjL1SyuVy9he1BJZ3igJPmTNOMPGZ2IT5CraKSCi3bzRaDpq6pM
w1ztGpRcz8wCWwZLQYnOdY4HyfKYMK8HYzWyKlW7tiim15EZi3KbjEd8VBUFqscWmxHvTe4xdtEs
q0eZEylXTu9VFMr1Kt4v7EPmTCrvRJTK9yI+lAGOI94KwfZzrlGqUMLeb7f9ouVW+aBKISNTJedX
Xdb/ZDhltS3zRxW2LQrk2hbvy9q2c1QV9hEY3lq5rqx2yrpEStlHY1BxZ1gk14WqV9b4LF7Q9CzO
NSzqlDVLscGFbVLCTqRUdsv4oRxrOBdWCdagv5sDaaieTfC5VkatR8FscOai1aZMF0TDaQy6lJcj
o0tSWxYrqlkir0yumCdkBKhe6Zag6/Ur2ef1oytlaquxGClYTL2uiSdScOhJIdWUkKCJhvFC2Fp6
VznIVvcGKC0AU6lqQVrrdDt0I1/6TRokzb1TYJJYQ5lE19utrdamq8Lvm3vTsPm74FIyNqVT1c3S
19mjxrlJ0uF6mZwuZl/XmSCURItbrcqRCCCBfAbrEr+1WN+AViwrjc/V+gLxQ+bVVdYkEi+vRmte
7YoE4/oaDkETbdjMBbhVJ5sT9cqyJgiZ9XKZiAcmmX613vDwCvoFMpIaoxR/POlNBz1klzrgFduX
5ZLR95kctKxcRFU+hlRkTLkKslCZdGQWlpKS+fpzzYof4f4ECMjUealmLWQnzl25z9DCPkvmkbCT
+udxOEythqMgGMIw0vGlN0an8WwlQDrHWxDEfRmpd3EWoKFoPh7LjlBXVeqyaQiqin5xMlVRXNtn
tyoIFotMtyIuLWYaKzOMQkHyJkLkx5buVpHb/rlBVyJiytbDGwuWS4gIJ4tFBKtZlTLTuWLya65V
+aGymmy3oly3jEy3gjz365COeLUdklF29nUnF5XLRQ4jfwvPfsb+5GTodwvlpo8igPChygeIH4iD
bJjHQ8o+H7XWbniGoJt34Pv39pEGTFxgqWL6iKniHFZjk/Ls0bAXDcRAxCh64t96WdN0eJtvWBe3
SpvNi6VvonQ+xYPoYOgZJzJd78oaAQqdDOG+yhTcn6U1zh4sRC6CXEjwyg4u8hjCwfIs3MYJfeVm
nOe1OQMmuRXgSZb0fyCCF6bxKE4m/oybb4FYhm5Xtep/VBte9et2u9tuVwXiCvvmj1iQYFHcM4ye
+2vN/hJGoxgFLfNQxq4hngEMNVkTxghTn0yB1AggRjhUPGAmVMU907Xopevwq0wUllukzzvbsQsL
VkOvmNuoDkuqjRhL7lhjkF3q5yg3FWQ8R3yQjA4zMCIpnXt4bqqN9KjrOUT44245YZIFnVZjHH4Y
zTM2R6l+GZayIsOUPmhUiDlPrhi81gqpbYN019hDuYpaLu5qKa2lgZg7iQctHrSiyLmMgjho6b5B
w8phtgGUbBSzYLKUtsVQ6vKILOUKQdPNc9OqDhcooB5d+op264cL+tpnU2HWgGJcHKKUbe2tpe3A
1I+MhnHa2nNF72c59kDbYj47ixPXJPhLNecIoe9fKqINn184TOg0etEiDpx/mk3jnSkFuHwYP8Wv
1bLj5cL6oVXVnAN91aZAzy7Y04c+Yg9OgJ4ymAsvLkUAzRHw18IhZJWdxIE/F+D9tek3grtKWjjo
HDnyAABD5ENo8KjW82tDPAulbjUKGrTeTN1lli/gqghDi6XmJ3Okt47zoBo51YknXoBNAqjHauiq
nCTJIjVdDcsLLjCLZ/64L9LC6byKPnBGPbS/LdhDrAaYlfdMbid8+BaRq2o6OAsmvmntkXPr2oPQ
ihCRQk5PYgj+B1i89n0UBEMoYRFG5fdS0jTbq9C2mDE6NAmaBUjtz0rQIxJ1pONWUXlcogrLC8BE
8eWg7WhYavmqYfECG8wfuxcLtrmiMLBa6YjYMFqqKWIRZHbmnOvWKX3h1KSxKpubeFM6ubLB1IoB
IBnzzcaqbB/aCstX7tGuDlztPIK+n8TxuKbjXr2+9CqKObu6EYr9sjOXh3Vq3uLFQoxeNMWiDq2j
uaxj68NHGwBZfVSvytyz6o672Q7TBrjsCs3ibLTClvSrHas6elQjxje/2uEKq6RO1unFR9jy/4i9
reyman7qnudSK4mrQc0OlmnFXc88/rmu5CUrQ15pIL+vK8ZSXAyJY123WpAoclQ1ipHkZLypGAZW
EYKg+RypyM/uKk6zGHsgDGJdr2qEHVTJkX48O8MPWeSCsOFUP8SxFnuFT1rn5nfuF0rwD/NjtqqF
Rj3bpR3DWg3Hd0ozk/N85+9GwUP6VRPJmoTZcw5KIQrsPdoiTeV7XcWbvoNJHPUO8d4O2/veT2f9
dD4A3p12NWuYAGSlNExXtfXs5fcttDfVqgdYDM8PzYiirvdlCv8PY9Et5kqQzNnR67nDAAH9Qk9j
rRBdatgXOWYK4MkpaGr10ihjx4KBmKIvkXKJFq2Gad8fh+d411l+dLLQn+Mwkhcm9DhAotQ99mtv
o9W2pyGMDUYUUK0aj0YovlUbwuOzV1VLQMOfgoR/K7ClpnTwuQfEe5zijch2TcZsHtpy/vCCqGTK
pivqyWQd1FvDoQ/3nLhnFNS3Qy+/QxoOP98e/+M6thAmMEVdWhJGCabnjACAtFfX9TnB0olZWSiE
e2wYnMxP2fnB0ytRN5lt7CQY+HPgKEg2cVU15/SqvmR0BAYTnMnIJccCaC4pEmQtPjqrOxYpbyk2
9nY9p3BDHVHbaQBmuWVOx2/jIFLm37ptVlI+o2QSZobaXnkhGBSwBGbIXU2uyKJDIQK4aFuHOllZ
9B7KyDCaiiwlfbm9H9HWv43tzQOpEeTrDipPCMg5wYbs+vwlcI8vh2pZCwm9aFILRxDBW4VUd1lC
lwrOowGAYokIWUXImHYKklz2ZXDXBMjxZhu+N/De5doO/crTZRXA5q17m0CQ65kt7+IMY0AUijGn
AF5AzCLng2Ki4gDzgqMrdwvzwiq+sA09dF0yvGXgpnnGF45QqXy3F97DngYUR1hakf8wT8ugF3Vn
QQPk2OPXnguGubrikEvtpcI4HImIePcCrLbARQzlDIZdFjGgnntwy26I0s1BznC1lMM66vUScC2J
ueVNOQCqYW/FGa2IWNwhdCbMxl9aM/nARatrDYcJJUWE4l3uhH+R/A/TQf8UFInk4+V/297J5X/b
2L7L//Cp8j889mh975K/3O1/5/5PiE3fPAXM4vyP2/b+39q8y//46fK/0Prebfu7/e/c/yJp+cfa
/9vtnc693P6HV3f7/9Psf+OKryjwHmO2j61WuygB1OqJn3w6AQhSLfcTv/rnSv7UwJ/0qSwNlMr4
BJ8x+UFBsicB8f/U+Z4OXr55/XgfXeUREIKONEG/xvwvza1qxZUMihJBZcUn/pTyQiHOrANWrovq
UPnZs5c/7T/pYyM/vDygRtyVq5Xv918+fvlkf9nOToN4HTTmdc6JkqWDEotWlmxqz0tVuinRqrdc
xql/U9uiBovwl4BPaGC9x/EsFac1xjBeG0kysHbONRWdcdklVV3Wy6Ysfqdu39Ve4pz+QklVoQXj
TT8ejdJgRudCFWWMADR32O6lv3XEV3QWeVpTt7bHdd4vjI4jHX6h4nMNGhMmOt0mW+DczJ5icnyw
VYNhfwrrHE5rfGth3pv5bRgNu+ydVjJ04btHbZD5GqsVeS67fPUKBiyBqLzFOmdV5YyNl40PQ8oA
5R692++6fOBVgbnV0tGzbV2sCraRXyB0dm4fL5wo+texLx2UFlPHA+VSl0VkSpaHInqu4L+6lys8
hgN0o826lw6L2C0vlO6h6MTAGo0BT8+dx+c6ntrZX3AiRzkvRRn8QZ+lH5tcU3mDWE3lwbH3fMPL
Lpnna68Vehb42JdCtKK5kGAMj0qvI8mG5n4AVMMoIYmI7looKIZeTr5zFBOExVVafLL8G+y5Vyxo
s6vqsTrZVyXzoM/FNIirdW4T9GL/qMkRqbbCFAzWUhWDcIcn0DUiIiyG9qyeDwk/yk0kJAX2U9V2
93BWuLFVFUb2FUd55tMAORUO9aKxppKtDHyXRDkDE/GSWQwnMy6brZoOquO0Pw7fUnRw9mSWmuKt
UFAXy8jf/bOpr5c5m0/CIZ62drPf/elADzUGmnLRp2A8LKQezL7m5yF+xX+0t4NxPB+mFMFMv+yW
zwH+4rS3qz/1J3qpC2Am/XTKTrn8NJmmuRKnoNCoAvjgLDUMTlUh/K17Ds+jBJYaP8uf5lfeqfKX
vjORIgsEAnrX8NgjRbqRi0VuIdVNaw5yrPhchqpZa2YoCVcpPLGhTZD1nlFeGUsWUXcO3o+JuZCJ
cG8pH6UVlcTP2U6iZp1DouFQu/3OWX/CQa/4KKtSPyVV8btWFR8r4vyPeT8O0hYE9Hg8/mA3qz5I
UslPItxpHCQ5ysEvxZzpoR8OsdARsXBEAPqBAU9c34qVgI/s5n9sH9lTcePA/ui4otPrpV3eWe1Y
wdNdET2MRlUEUOd4zI7hc54159iB3jKR6i6BW3fgk4BDDz75W24kmx/xzW6rsqOGh/XYh6uMNal+
hsuGtTHHCSOL5XSpPy2GbSHzWZEBOaPcSuK5quZyZmEuLmazFMNZnuksy3iWZT7LMqBiJrQMI1qe
GS3HkJZnSsswpmwBb8hmbsJqlmM3KqTIxXKUVxS5dzo6rsIXK1ISyxb2xsFLUISWj1hJPI+GNXZR
gfd177dep93W4+WXZXirMb2FjC8bbhHzW8gAtXCtAia4JCMsZoZZF0UMMfOskdTSERn20dnUzdkQ
0Waolo2/iNvQvaGrM5uhf/kpeQ1298/AapCTWGMiJlNkbMCPzghOw9YBsydjB9s6MC8UBmeGp2fo
qohBD/Q6TqKyYE1JiLBLZQNxhmkuQfzUDhoZzPMK2rwGBpUnhsQ3LchonLUIPlRkaQDdFCTUy23C
RJMSikFSKJb8c8oRn1g6WKy6lqmvWtBqrJpQvx1lRCPyp6NEf3rmZ+2Ipztp5hakGdrqYTTkvZ4I
ky+LJblM0UJ8KbLLu8lMVs86W3CZfvXCDvuvRgausN/rTASS9awMwsVjcdA9imSLWEvUF0TV0k8M
HIRM1V2WlolJZHKYbOFOFlvWJHBZJoqdBjEd98pG0xpn4mM5S0/8RMEzwj+cY7V6XmcbLSiTUL3Y
JoGsQNpSh5Yg3sXj88DzPWAcfuTJzimfPzTvBe+mcUp5IM8CdcXALMbTXwrCxxPZQNwYqwlbNHR5
zUK5LVl1yXkArOsLONsZyVo/A/CMdmHz05ThPXk6s58zvWrA/PE7ElHkQwJ8suZ1ZUHWNMzHpp0c
G2nYeEj1a42oq3xqpenTytKlbbbaVRHqWc8nj6LbFYRbQf5OBef9CdmtQgebnXZ5Hn3rTgUj3VTx
hQqOxRwZPiWM0Yg8Cy5UWHSZwmoXKawwrg+9N8E9j5p+T0LDu/l9BK7t4p4Ixz3Y4yk7vr1JL8td
PSBCgpdU9aTVGJOJlahsbD9eJv/V2J/pJ7x0rpkhx5jwSPtakmcJahZ7INDHAv8Dtxppto25mwrb
xo+rtD32TwJM5oU0hsNKMZhEP+WGDyAISPpnak10ZoqSFPoC4Q+ZHIWi68pbqlsnsCpzzlVVniBX
hZMJgoxotjw3zj7AdsMPOAt4ybNB77PqFdS5blxBgevqdT1/iJsqDx0NY/WEhyWR5oYj1ie+oUkt
hHUWwl/1tFhWeZUh4GPe1iRA7K5WfD/LLV7ItMRlTE4y/2nuYiqmlatfwqRfFziFRvpxojyrCCkp
ntERkk8r7XQIM9JNSs/Fmta4qaRxukcSk/P3ctRcCYez8ky5QN4mxzqkHeRgV712Zd0QNc/idEYp
1D/rebYrn6saxTRzVZwDR+ynKBLVqjnvwHU7SUfRDV7mGipHPZPFpf4ogL5Pw4hFVJBQrPY/1wkP
uUGc4E2K8QndqzwU7SHz1JoZh9HblIU6P7KaQ/h5ArjBOV3KGM9Pz0j+HsaD+QRIG7QbvPPxrr3U
w/hugnnLe4FpT6zmUozr0WV3WKzBOPATD3di15uGdO2jRxKNh0tDZGc+PU1ApMVPVoPaNNQ1TjEJ
eAcwdeArGOSM1/aRh651vR+nnBSL2ZfJTnm2PYE6GKM4A6WgZ+MGMMPEP8X594ADITuC5kqvjVs+
yb7mAWUmE7edoCxnKKNw3h8qM6kBAyK72SQASjdwZUambObdXC5zR0mp1JTnT86lxMNtU67tq1zi
WJTPWvCXYwmBM2u3eGikxa0pVUoyVVOKz1tSoOoLLqgrVKGWvpauRK3Cv9u7pK5Ef/kHX09XMrJb
1qe0mSx59VwxZ/713zlXNvaPdNncEl0uvGUOObCeDlNzUnQPiXxiinOrl42pwCfSTNecKYFqTEjZ
G07KbmuGWRXaA076rlEZ4axqpAOVLrCkKOWKCr9WVw3pDdvw2mXwy2ueKCU59dYbwhfFGIlqSosr
HVJOYbWHpNTd2xiSUiDLs0wLt2Mjf7SjgPQ0dpwF32h4CimA1/vWbpCBE/ry4ztrJrKUxq1dJxCy
HE/RHLrWk/K2J9sBCH9RX2zavPMefXC57hENOba1GUv/qGWtNwylX9fzs4XJrYActJYYRnplK+W2
UOUxtFapWElXZT3fEXaLqTdUVqpgKtQtMnxk7gyFXbGjTGF2ns+9wzPM/R7OQn9shtbJvhU/mszh
P5RAFYjYpfenP5HI9ac/tSpuFYNnmdI9SpfeFGRoPwHC/Kc/Iez+9Cdk+Sknc1aCetbUKExI9jJh
NKrKUa1fITCuDa0VD2/QAI8Eu0YNkC+GnosoQMp5lRnVhsRcdeMet3Lt2gfcpHyhKbCnlBWqYyXX
GQfyRCmtew9EUijaG7JJfODaD7wdWyGgPN/m9DOks/0K5PCxmuW7ryUZI08Pc/LOuyippNCXEWbu
0zYxN/Noy51bJoha/nBYo4brRZufxp6Dbgbhr3UQz+JxkOCmh4r3d7babR54MKUklR10r2CZbXOn
nQm/HArqJCcSffIUJQOWlptSpKpH3eMhZ7lpZmM6tjqkpKFokezxxS/CUQd3ZdZOvb6IZJmrTi0f
dQmtjk2NihHVrRKKb24NkD/mw2Dy34ygF3sx9cxyVlzi8uk1LaPnP3eGzZzN91Nn2JSRrf+YJJum
74nKuCk5hRnF/WXq1b5sbQEq4H/rlgXClHNZ6eZ7DqFqNTvUVgfEZfWdO2SBpeTDstWJdbjL9flx
cn1m4C1M9yllqfloFL4T0lTxPQYOcC9Ozchtr5aT0bJVlOZlvOIOrqv/ZNlMbReWf0j+UoEiK6cw
lcTq1rKY5vQF+94robHZuUxlvYI9l81QKhSNktDRRjFBrf9qU37KXS4mo7J/uhJ/Kh4jAkFFDlDH
eogoplWXQ+lo6MFmgpNbpIZTY8asGmj+4qggFNXMY6TKJKlOc6h4Zgr7crj+5VCKtDCofH/LDLQA
rbiwgVVWAFgJUpX0ezs4IZqUKJGfeRmSCDgKHKH8sGVAzOMQxyZ8AAqxX7gOI2qyjy55q6FQVm8J
BKLCN8cf1xgLsIeKGshjxnMsjTtan7eDOdzgzRCH4XcTvPno2YQl4RN5dAWKiyced1mqYcwt/M+U
NljyBPYzg9Lf+eM0KMssLGrcMLdwnhvnNGJtBXLpheVwF6UZ1sXD5TMN28zv0yQdlhsqMFIwVMn2
+wlTENtg15MQuyrlMAcV44qNOWapPEDMTYbevtqbhjGyuruy3JOqLr0oq5r3J3CgOY/AvYKFmG5j
u2D09cLCFo3J4btgz4XofhOUXyQWLYf1N8X8BdivpKVyjC2CXWHmbMcKE5584AIzM14wRomh+eVl
HvppVpdH8Q9dXCnMLLm2JtxKkqLzlXYi0b++7xtenppQq/Vl06qrxv9pkqoX5//kmxoub6GP8vyf
m/e27m1Y+T+32jvtu/yfnyj/p8hjqGKWRG5CoBzoEaicqzxAi9tM/Ukl0GVsHJ7Ir6/gUeX5jCeY
XrNSqTzZ/27vzbPD/uOXL757+n3/1d7hD7D9sGytug6ENUPd7FcLq4O0Luu+fLX/4qd9qLn/uv+7
/T+UNpIGAyAf6bqWGFK612ktvtj/6QCd35ZtTdxU52jpe2xq6XbojjitFar86vXLH58+2X99QCFS
8lK8hrxR7roiR/t473D/+5evn+4fKOfH6mkQBYk/Frb86sk8xSs/ZQRudRYMzqJ4HJ9eyjfoe5qg
yW9Coie/THHVVKV0EAbRQEa8VpnCw1M2kucvn/AgrJtGG8a9fdcVhk5JaXErnyxpzjCbnFe9iJOx
uMhYZgbM5mrOMzfHbH7a3NS8slk923vx/Zu970XnfsLZCLlB+i+1MEq4MiUnpNYjGmEU43+n9CaZ
U1/n+N85DfsvekePX755cWiuo0/tcZ/k6VT1qY0Ten9ySv+lrwOf/ntG/4041oP+S+UHf9FGLYOs
xZhPT+i/PP639F+qw/kXQ54RzYXDcnl2fyaf8LdUa0xvxuecu0C2PqEkBhOO2z+1IRLRiKY03ulY
gxF9TVINXj6jBP1XjT2lvZDSeGfUyozGMrsg6FKdObXCmQL+4itU7R/s771+/EP/u6f7z54IDKS7
4fNpJlGtRmTJFung5WsgPa/VxkyCcXDuRwOa5jSGze0nbCHPLo/fmylUtqvrZchFk1sLVIUXb549
2/v22b4+2oJB4trQtebXK6WepYNhPkQm0KKreJYpFreICkW9f3+T0374kyCd+gM+JMHwpIyonXc4
XpSPf/vhMF+mCXyHC70NgikdsckuNtsqCSJZP/ogibHMpwZhF/DfmQU2hf3l36YJkPtkdqmMR8ZZ
DBAdEOLckTXCoWBU5dgSNd1WwuEsa+tr9ev19DKdBRPzYGQlyO8NYXY66IMIzz4AYuhQZ9hi0Ecn
iBQoOxv3WiCetgSs9UW6377fvknq4eXGIW2waiQFaaAd+YmtI3FXtmJnEc2iqXrlDvRgny6xWPhW
Jh6IYUWnqiEggRXdmCFVMQlN6Q1j6eHZjhDfTUVOfW7fN+tnGdzg69Z9rapKt0PV9Cjmfi4gfKXl
za5dXXltpdDBCT3jYQZ/k2PT9yymPVsgcWe49VYEIebXQFxmbjcirw233otbra231p3X1ld1N7X1
XtwCbb11Yoq40FijahkFZ+IobgS2GkM6JS/Psxa6EKuKMWAh+tuy7Eo488P8REcZNEd3NT7BvSPx
6uo0jF4LWmD5I4nc4hepfg2wTI2MeQhmwANw+5hpxdkbJzuJh67CyXyi4EDX+WVv8ofzobRT3yQH
OTmvwVdOrvJA9W7FV/+In6UfwhUO+Jp9P0/QtZcW9zRI0Op0JVq4zjKMivHn/IG5z4dqfiv0+QA7
4mrX1XphmnScfCG0CXhYolsQbu7Ojr0EQKhK4EclIxvEcTJED9egBBsUKhDj0BCB3dRx/PTr9lPQ
LzFHTtliRM2jPyw5B1HrRq5mMRVcOFH2Qe8mC38SzC7QY1ehGWFSAS4YqbL7MQmT/rg/OIvDQRnc
uQDS1YA8f45N6akQU0w/9mWAiKKWOp5TQKTmZFRxaxxfBEkty9fLpXDa4qfwypWjXmIA5IeSzqco
Uyn/qnKgzS7i/jiYzdDFAqPjSnfVrw9U8uwWnusYuruhLgCgd60w9cfTM7+22i6gKGlsyfc2mgwd
D6FTBtFBer6AATAu9yl3VhHR/+gQpt6lV7SReUF6RwvQT0EnqFUbnG5BL3xs0X+eUI4L4MLQl3rG
CsTclx29iKjyQLieYAzwldHMNXyfTPxmisEGdNcvjTzNGBQOAU+reRiEH9molhmFCukazjnqMzD7
EIgAUGJXSm5ZYoQS/hz3jah1VhifIRCpxfK+K7rWtaWaqlqboKtFUQTjIScxJMzPFlD3mPCjyxqV
lNTFYVRAZOAy8J2bdboxahArHnAGQ45dl8SJG16KRIVpfH+n3flVkibrQgVjRSR2ZOI72psDsm5n
9md6zidXkl9aWA8gMEIfmpkgdS0ZpF79D7ScfN1ud9vtqpkiKZtaQQafsrk/PXjpIcztcE7XQikP
PRKM+6SmiDyBGOhpoL1DX6eMvZRt1/ag0gMjuEZtpetrckh6pGGpGPWxttwz3XlTqJq4MUnaVIFx
4gPAnbTPurlb5e10slTd0E71ADv5DhfQbYgommx2X7mMIVTtf1Zo1SiDi2P8qkUJnjVns2sSXNJe
0heX92gxrnpQpDKa5MpZ0ZOynuCNRM31LgS6cNyPLnXrpdxLo4bU8JrftBveN21rbHqfxniLO9WL
FfSqJgjdgpLcQE1ZrbDENhZp5Nxlf7DC2eDEy1JEl81d5IIuUCsPYftmACZerUE/b7ky10n7oAUT
o7nBXHc2m4+kJqEr/HpB/b04XS+zggkaN5KqLbMByhhVsxwIrbHCRq1R6gqR1AKf9c4pL582Fl1i
XJKnFNBWBzYskNG4OxxmUbbCBduXlkMFcUqJ1mzeSIN0s26MRXV1Vymk5FmyAsbVnvg38/SXJKin
6J0eSE/o2stH9ShU7jnieQyM6BlPKn2jKqxPrkdnoPqbuj6a6LSnL1b2yTbN9kyDkdoFdjnYCTvt
dgFvcRQWWnOPKmUJIE3Db1HnVrEqkaaizvOF3X2bRuWirs1S2HO7uOtc4dJZk7l6wZQ5EX3D27pf
PltZTugfPSxvzRRt4OWzpEyrOMPS6YlSsqeOPjPLpFrUnVUM+9wu6DNfVHa8IzuW6gyd8y8j49lG
+wUCXlb8FqU7HOxti3ak16wm18lDiBtIcrp6ptwpliTPNNK8BCdGs4b9rJEnxpoWGuODRN/Hg5KC
MxLxSc0TnzGwVKsp72FCc82Q3qA+anpYYG43BTXtnIaFKs27ogBkE7r5VoKLBiVAZfSbQUq8xllR
2Chr6qBAiWtA65kwQTHwpJ3WjMbq9cpy7J0AT2OSQL8SDV1z9gM58yv5S8X1cZ5hDb70QpOw8qCg
Egv12tz4uKcC0UMOw0hpnH3pUx5jTOTMUfglS7khzoGEHYaqoylIa6e7CljNYeNBgdbStTc48xN/
AKwhLYG0TC6oj5pdkkgMZhTvKR8eld2EzwdXhnGYSnl7SIP6HmmdOBOU6y6OGaUBSC2/eM8I4LII
ie9185wR28nsTllryn7EiVL1Q8hc1+J9Ydfye911aJlrzfpe2Kpdrm4eemK7OYuQ6gSLFbZMH+v6
WWl5Y7O4sCn4JNZNHvjaiqx8X7pz9cqrb2BZu2gPq+89Y5Q5a7pzO8hNbCg/amNornC0OST2SoOv
eNaMj7jlN9ormw9Fu04z8Ea7wPKL9DsbIY1as36Ko3tj7cWRUbZ6Isew0FwdGJCVyLm+mZcJyEVA
0KgHjaub7o+rAki1aB75EJlBKgOtm4ZftYQma8+tYk2CidLocyf1my7fgJxwEUVhwU4wJpszHjr6
ILDwwD1jiPYyCktD8RrqpgfHAorPOQ9JLZqRvST0XS1e2Z5x5dc5UZVMVpHNWjigedWtDmZucSkc
kK4dmruJEUqEIRNi2aC+pObw0/ZKuRkurIvq6za/8BMRZKjGDzMiTrlg79onlzfYxCVYVdj6Mui1
PCWwnYRvkw7YQPw0eJ3zFb1FrLZnpOG0KXTID4WMXBUwpyrboyTn9lGZ26nVOC2TDegMcNX5q0EU
nZyxGCnPzwz9Da1T03JnqgViuzsKYFUTrj2eepEkZFpg9ZyIH2CeJDDmbZPs3hJHTT7eVzJTxW2N
+CALJTKtHumq6hXpBD1W2qy7AtOe+LdhU7ye+Ff7IHZ8T/7QGpNSfk/90sxUTG974t+Gni1WJ8g9
6zkrqGTxnvrV0JK08Sfxr8M62rAJUU+Sktx+7skfGkA1F8Qiw5dexmVpY/XcLJQZ2nRL2yK7Zbmt
lPpx2Ck32+2sQ8pk91GMe9T9Epa9xUZudZ+GaQrsk/+kMAbm7H85z/AFBkCt/IdaAGlcLrvfqmY/
asgy9rEbu3HIRW+Qx2Q+7UUz4LImieN3yxA3Ho8YQSkxKwDsYmLGjffMMWm0DvZqEU7iN4ACeu9n
wBMvFdZtb29uW3iESZgkFiGXyDkCayF2hFqWby/pEnT7AuVPryYnVUplfQbse6wjGqnoIoKPMmbX
uIig/ZTyz9Lj8V3hYsoKS+DkJEzpprIjrHNsRTWmsGdCuutHRa/IDITaUUVaPBD8aOIUvlkGoyhN
B3W4mDeqGJLc4NQXliC1OJq6GUiTq6m+GDUpuqZosqozc8ZZhAtPu7peXTzzbEoLd5PDfCPHbg5E
vV4a/hl4Fi+CSE+ZebLXtBOvdNbTF75025rrILYphkfh3uVEasVb10CHngv0mqQiZ9fLQSYrpKKo
SkepSsGwNttqoNlrg5Hm4q9K23aUR4CoTlzf3d3JaK5lu5PlzUm5CtT1S/jQmlMwMHS1LGhjITK6
mtPM7cVjEwZRJYDkTKLqC0z06rpwVxkNrHbgV3jWJ1ihYhzZpsH59PA/mjCEjKuXk26EloNvq/qt
m+IQtVfmAGdOilsS5Y22UGbrFR6xulqhY4tMMvvPEf9flP+BA5vXb6WPdru9cW97uyD/g+N3Z3Pr
3uZvvO27/A//6PWX6aM/KBFIef4P+NvesdZ/e6e9eZf/4xPl/wBSzZZS5bMokvhQrlkQ9wdvMXk8
pv74zd3fv9b+JxT40CxA5fu/077Xsen/dmdn427/f6L9z8ntm3TJYSJyARkUgC7/DoZ4wR9mBEIv
zjGLbt6bp8unBJJ5fWRWffUCwzGogdnllK4L5Pd70aW64EC7eaDgboOiFJ8iF3yfrwMuz6oMM3tr
5P1/Bi9yqaBV0HKWzxyGmr9MUJm5umzmMrNti2t2u151GKbCHFaxbgJMVWoyKPcid2kElxA58IoL
cB4153fhbSnTqTrLsJdkaRHqhrK2Lfre92cLi7wNo2Gu0LW1CBwe/ilWQOSsdQ9b2LX7dGjwMYBz
rV2BJK9fkBgoEtAbORoc24CMdhmCu24nEA0eKYAhLMXvsuIMQSycZcjVoyvogCsDryuFrRx9xZ04
UXWlgfHYvsxqYRWE7A1qESYe567lsK+ZKCA/N4U7ZUZdEej5wdnp2wsGueAKq1XmoI1LJKKvLAKz
pG7HnLex4sooKatIZwBzdep0oqqoZMHi0lW3fSO/JM3HvMSiIMs57zJBALNbwT4aHHWq7gKMVdyi
4ccUkEq/bwxOyVJuBZpm5u9/CDCZAy4BS5PX3QYoBfO9FUhyXlSGIHYhk1sAXEFByyJzVyBDMBVs
aalN5NzoInV0ZXnKLYZbWYlwF+LCkgQcf7gIOF9kcxMC7kYCdYC5ChDl7Txa4voSxCjNZ78Uu1yN
Ta7MHjM5BYW02xNSsLVlJRQu+/HFE+5nednELm9AXEGQzNIfLl3kAVYgWhRDyx6TQcWNBFUfMsSl
JAcNdFIkX5IycE1TVMeqcvyVm67rymuqU/APIdtFwCumxs4JFZPiojnloG3j7C0QVPKmWY6aOhDX
JqVp5E/Ts1i7CcpUGpccnTjWusoNpJoZGKpd2+TQyBeXZ1GsvNYM6lp3lKdTJ6MwvrFKXldu2/43
jk9PgQDg3SPz6QcaABfY/7fy+b+3t7bv7P+fyv73jJfao6Um71rOVTpc/zPoAZE/Bkb5LhjMyYEG
DwrQCEiuTh5giXceBhcr5gUXJw34RuVlQe85aREUyJe3GBZaCZ+9/L5/sP/6x6ePKSFyrYpuLeJ8
n1I/i10nQkSr0mmqWq/0n+/9vo/191U+5e12u6K/6vLwjkzKgQSH3tcm/rtxEPXslurcyLOXj39n
WBVfC7Mi+2SRgTMcXQLRwe2WnId0UfrpKQh+BRl3ANrP/anne68uZ2cxLQMmDZzFHiavSOk8XqyQ
aNAbheMZCKm0TtKlBG9zzvqxc35VW/nw5Sq5XOOgcjl3ZAlndY74K6xLn7OK5PigipOzD44viIYp
0ugalzB8jkRD9D5riP3iSlsSWKA+Ee0WH+cAuTiJXB1xNSMlFaUplvbqPkH/2/loFCQ/kOdbUhNY
3RLP9cyQHUzCmaEZd+UWaMHmfE2vHOw0d++I4OdKbUUu+pzfaVZska5on/6BPVjURvXBPOIkSIxQ
uNnF14dVzb2Rw0Qsy+sMmZYYxQAQf6Z7PrLdMzgPxlkheqQ8IpaRlhEYCjo3iqhNVyraHRBuZz04
GhfTgTLi11F3CzjQscvuTOKB2tAm0PRdL6/sJsDgJu/vPXn+9EX/h70XT57tv0ZvWBdy4PR7ctWf
vvjupaQPMHq048EnlLtp1ipZrD9Gb+ffNjyO7hWZTjfabcIW9Cy1aZYiIK9lYilsHSo2p0lMd09i
R3j5yQVeS4+TCCl5TTrLiAeJakxXPhOj4LA28VKEb+hEucytaB69jeIL5iZyuaUHMAc/01UrfNEK
SqD0ut7wcgS3XilbKTkZcYm9SaoL5uWqfcQ4j5ySf2EUpPhK2iW8O1KIe4zGFfFwrFMMUeWoyYt3
rPgBqv6I4yeEITVr58MqPMYixIZh3SbBBMORuLBXm6cc0DWD5Uvr2ZoVAcVAXeo740xKkRd4yVgq
0cxAVnOM8tOJn4YD2w9MoDr+Vwt1IELTq35Z89MBKhf11PuypogCPakfYrPW5W0Twgk7jvVhAe17
RhQgY2nWThRoivVa7J6s3wdKr/3hUO5Qs/J/dv8vjES5ndt/Fp7/d7Zz5/+b2xt39/98KvnfuOFH
ULRpjHscabrGGZLsoqBZgsJdsvLhv5+cTv0kzUn6iy4DSsNTUETyCgFXbMkq/f457GHMMNUXX1gE
BJas9AV8cQDkOEhEEUtOlQU5ME18yheVmd5EaZVry66AtE8WckRZNDJP2YYeniHqi5vR2A9DtKL5
QohShrIui+Wotyis+cGrFucn5OVOL0Uxvm5VlnhDT4/PAEsAbqRvOUltn1SJfl8FLtFqCx4mF7+1
l5zO8VqdV/SRSS4XJKucsxSm7jntOQMXuCrS6r4v6mTcptpsMiS0w33QIDn2SgvW4/jJnmuJMrf/
YDztjaqHL58/s+JKKARUBmF2vStHM9d1k1uxEMBjz/xc5ifiOq4CN5eG6Lifhe/IV90MlYrOB7S6
mKsie3IVUyUqjsv64KOGh7aPjEDbvMeCuFbOStq5qDadI4iqelIoqx65/QvM7plILWtjEatW5kwu
tm43t5kdN42o6sKFXNU1yEZZRXZ6T4kSdXWyVFaJd2V/wBsRihgbs6bRP9trSSx2zsVJGSMUupEK
bPiYFKFT4TLrt1YWrrU0+LrLOQzeuZWCidhL5eq6kUOPhj7++hI9sV1AV6Jzt8IWDtE8BxDgVUdj
S8NW1WiV7gQLqnohx3hN7MXB6uib6251SJodLAvG/LAMGHIrZdDTRpjrU169qWO5+yuBvBC0Rsiq
YxL6BocpaDuch15ewz1sc/+3QIEUGo5253kgxAgpqgi+8dtGdt2KfptPQ1y1or8rP7vRSIk5bWio
r3iHHmtqM5967qhV1aSlQ/VbBzXdKZM7G8lbEpDgY2Ky6DRQmcAwWZNQ6pOAgFot6579Wq3++fqa
JQYgzOIU0otpgG8wFFBKpWxJ2dCyocnX1uDkqi4xPHVluTUugTMqTso1KJKNrRHRO2s4hE1LjIVy
ahQMhEOtcteD63ApILelFw8X0vZ4WnPhRJr1ZFGkxd3kCB/1kd/zar9kYC2YdtEhaBEl0+ZRXlWQ
OUVCTGwoorNkQ8SCnsIqQyRGghHPZxLT8cgGLVbyFllzIHmiJWP9+KYpe2xl7DMbGKPYbY6Kogat
IdHSFoxFsgyDFxQij4sJGKgpm1sWG0sw0W5yha203DZy8GHeAqQYon2pZt66BbobJTOUKmOLfqBK
J5lw3iBZz9/j4GRA2IjYasadDbWXB0SOGhppqueub8Ab0sWl5I8NbKKXruvRhXa3IVJOwsz7wTnr
JZnovY9vzI3HKUQYo8LTaD5peKMEzZ4KtTzvc1iWn31QGV68aLc7xiDDaBTXqgdn89kQDeqiPTYI
swmFx8pta2ulBtjC61tkpkyq0eJ/auLp4On3h/uvnzeMwdZLyz99cWgXZxVY2JN6mtqrr5RUbOt6
aUMuMhZemwRdqS7yWYYwirEejK3aUegqVgtvwkQrsbBhkFNkv4+Y2u+LgwBmYwd0Pr7/DjphPP7n
tQYX2n9h467fUh83iP/d6NzF//7j1/9Won+XiP/Nvkn/n807+/8ns/+T0jRL/IhuOKdjTXUkcBf1
+6+8/4Xg9qHHgAvO/zY37uX2f3v7bv9/svM/NBmjwWLmsf2EE86gfIu0ANUj44hw5UO/Qnc+PQBY
Pkz9s9g4owJhHB/lUZ91pKbdM8zfp/4lCv7qGM+4xl18XPIASx3JZOcIC05l9HuPy89gCg5X0iAl
871wIV4YsizWikrmFQtbm8XkpsFwyTBnVZzy1PLFPUbIbfaLcxGSQ+SVFairjmNoScVhjKFN4r1m
Jz6QHcyDKI4velxafNl79fRHft/6cf/1wdOXLzZMPy4t7xXboLJ8YUa5aRLPYlBYuXlcqvPNTsdu
K/BR/aZ14Duv1fe6a26tmFIX4TJ4whLWz14V1RiGqaNS9nZBT/0RYLWjO3rvrJslkqIkUnhWbK5D
lrtLANGRnsoEVZZ+K19DfloEPDaf99lXr5bfj1VFD6p1zXz2ubfnPfPTmfdTOB7LrOfoRUbkiomS
p8EYNw/sqcm05f1plv4JSyUBULdAa1GE+nkXZ0FEzVDbF0B/pgnmvRe3xUF9inz6E8z/bZBCSX+G
KRJgj4SzlmYvH+MCuciPCXcVtdGwjCwGJei5yEPDClHwU0DZaka/AazpzGpXQWKJFlVZmnCvinPq
C2/O6qKVpcI5LJMGdR0soIiHA2unMqR62Ij55ec47XXsiSOlyu3VjFRn+0NSa3F2NU+DBO+5x5u7
fXR7ZBhSAvIGkotpkMzCIF3C/EIXxKrKrTClrQhoaNrONFOSzWwBIdF5T5iTtMbqTqsx033lspcP
VingFMLCY0F6SVSNPhhTNctjNIqRDQohk7Oh14os5EujjPj3plijrScOsJUM8IBDMYz+/uvX/YM3
jx/vHxwUruwbImrojy9m5THgDBB3vWTQo6UW/dTzpjwT+jrCcDqWL9Pul+mu0Sw1WQhESl9a+BUF
psaNFsC922gLFGy5JbbUAkxHKF34SYR24Nxm8mczzOnp4QiCIYBoPosnIMMMcN2TS/ivuAxhMKNs
lub4M85RSDCyIv0Pph0LJroCaTHhkY0R0GUeAZOin+PLMhqTP5LPLMu5Vqv1JU/lNeu0PHfhJWP5
kK3SGrIpCc7NXCTo/fQyGtQ+CrqrVKeLGN04jqd9aZXOwCG2vpKjBSal89EofCdC9wWtyq6sBzol
3as7BEU8lTeOtl4JiuJ7smHPn06lgK7I+UkwFsKQOjQZaol79bMucb5rISFgGTEKZxgkOQlomeiB
FsiLa0fVK+M0WHWZcCbatfW1+vX6FYOhNdZeVm3OoANZsoesr0aO4hOVh/81dNr+gRTd3FCSnDNV
IfUYSLAi5PrgckS9GHx2GA9VxSOMPnTQVzMXaeo3Wu1cLI84PKHjq2XnQAuETveINlh76OHBKM/J
mMwSc5DJZXHkgDnqapOl8CdC3/9x+BfQNRktcO0N/MA0xy5PFEOldYVIO5XYo1yH+dRRHMSEIKh2
9XXNFxLYB8WckgeXkfDgKGFbp3fUADSGgojMVqCvBUmK6NcOEMV0jahn5EaBJDqmd6EVEJ1X6a1j
deqTksCh8qUokA5diVgiDOUsTMmvXDiRG5RHWwceIYyKf2jprfn6FPpK+RoMp8jlcKEweFsSY4qu
FgFbdhkKiKVyjSzcpwS7WiFIHmkt3xDtEXvC4o6GXGHVKZ5C5qoVF9cDGPO9fe0ZO8lKMLaMI8Mi
BrGKOlGi/d5MA9a14NMEmM5oDiqoOA23eqjnSG4Bx3G7ziyplCxUTAqUk0IFJT/0HPtYkYUsxUbc
rESsnbHUeI+OuMHpJNBpAZlbPLUabllKE7xLhS06ur87vfnI5z/Slv5xz3837rXz+R/ad+c/n+r8
54DDuyXlxiAXvNRXBpJmZz98UIxELl35DOjPQJTN8x5yAwsiVD4Ve1D6UE4QMRMgCIaOjbaG88k0
rSkdQFxRGidpD2+Da3jVLt5HRzdfvQ0u2XsPOXmKY/bTQRj22OdZDKmYb1EUFutq9PzbRsXBp0i8
a1QyXuQQu/izMq+yyldWoq/yvXl8KWyEdl0TKOFI5OsVca1XylyXcdnr0hug9TvvDJouZn5F/16r
sKuixTKk6Wo6OAsmPkizGo9TuVfpX+095Q2w5WOcmgKFFJlYGpRF6VPdaEgmkjWBqI/BXDjRsfVW
tHldMSwxXdt+elTlDyJpIP40Y71deC5Rju+i66+OeVRPe69nxypEqhKs/GdGKIIFYhT9uCmqWaut
A9TtEKvW35mZTH9Z/zgo9BH5v6D1H9f/o925t7Gd8/+417nj/5/U/wuXWvH+vN/Hjx3LergU8yfq
Rk1nd4kJY6dmB3Xy9lH1yr7sqsx0KAgpOeYahNTqGNmneW2aq3NryEDvuOV1vWW0fVcOX756+rh/
8Oa7757+nnJHMZ2S6ZCMoWCqcfHebKhh1slyvqvi8pVVUuV+VwXFG6ucTAGvivELUYoCBOyB4kvn
KKn02Mf8IqqceBQlpoP+KYAuP/npYJ0+ONtVtYZ+enYS+8nQqJK9FeU5QgJ9E8JcR/xtHb85+9Lr
Gt3pFXM9ThO6YjQ/LX7vnpWog8xnnuqlxRur3J/jE70QPlolZmfzyUkEPenlspeNykrJAIvoPwca
3k4GkHL6v7nRvmfT/632zr07+v+J6P/34QyvABIJH8gCA3vg0nQEllnl0ANmiFl54inmWaAAvggk
8ZtnAGz5JwNZED2+sBuX1mh5EcbpwqQhiWonDQZA2dMbXUEifgJZxbtM6YTfemdkNBHvRLjLcp6G
MlvE6/1XLw+eHr58/QdkU8/j8Wn84xz+s66WoarKPtn/sf/t670Xj3/AsrAk2afDp8/3X745xESG
rXYFc2S93n+2v3ew33/x8pCY1H3YZpWnLw4O95496z/fP9x7sne4x5eV9wiEter6uZ+sw0wyurBO
Fwdi2hfJjlq4PsAG37yC+vuv+69fvjwsaaDJKJaoGjCuf3+zf3AoezbaWfeqYXQSv6viLwFO7lDW
huEfvjkoqizoa/ZTVD7Yf/4jFtsnKbs1iCfTcBzUkup/PX9Ua78/6jS/Of7j8Lf1P7aKn76AKTx+
+fz500NXO0ft5jd+c3R8tdW+xpKV18EYxPngu2A2OKNYcInnR6zl0H9GIM7PjhtWetrjyreJHw3O
yuuWNsCiEQfTpcEE48/PUUnLZK/ZfArtodnCk//JEsVR+hWMXGYC8PvWH1r/gecN5/xLeGyqc52J
DwOFYSowt0bz8Zjecrfqimv9Vkr6XqpKvtFUSTEU0TWokdTwZ8m1eR0zTYsSxsHkZ3UiaPgLdVnq
sHWaxPNpihYG73PKCgMK4WkUJ8ERN9GkhiUI+6ch8NmTPuJRDfa5kGTRJ6Tvn6J3ML8QZvYur0hh
zmGB0wArk2a0XvO/2ckDfNeT0PhDmHjPSri4N0ATPsoEmjvA+nk0bPGovybst/IfvoGhN/dOWdjM
5mGV+n2TWURzbxo2hScudrTR3thodjrNjftau9d6khvjbILO6qypwiPdJC2eFex64l+KxUxACgdG
ERSdNJEZkAzVNVm0hQS+Vm8B2QGluVadz0bN+9W6EfupU/TWD4eHrwjVcsGfjIv60Qhgo+CZWMu7
guIt7AbQzyMmAi8KO3rz+tnq/cwjIVuO0WiC/bF9oKjH2psoxBE9oemLCFcC0385ePlCe1tfZhhy
FLwnyA0WthBsjXDoYXtqgezR5K+cVWZa512zS/cqz9ytVErSuR836wgJptBTMJAbCTCgB90THANa
ftjetQ/DsRdJlsS4BdH3JsHMR5cxRSEzxDUISpYKsXo2m03T7vq6Pw3F7kX2sk6jX7/KJnG9LiZm
aWBEMxy7WUzOutpYjIdTrg8TfzTDQ/eUXAs8Ipna92kSiD6zQksto4CRqCxtaam8O3jBOp4QE+wj
7csvIn+81RUFcGPmUTY/ekLcGaPb4AjmD5hMRyO+IQrzMNQys71umJF3zmr28zyeBTUuC4zbHwW9
qjn/D8cKHj28FGO4Xg0vGPAUPi9Evr5E4lqWdgwm5pQgyyHsY0ZBIUZK5SHbIt7zME1R/pZv4Icf
pd44OPUHl3KDiQYUpA0u42QLOGpiCf1Z8A49PQAs0E3PyRe+AzHuRTz7Lp5HQ+soXDqSVMXIyWTA
KHztTitwc0JsHLdnHsWJCUIFKPRDI7+tKaWEc2UjcA0bc6SLJtQldbBuNax/vSoRX60b9UYSAyDw
vOEEMCV69EwSJFtXBEyWU8cUWaeoF2HffjT3x8ZhxYpj1U8ybLQVw3WSL9pFImuT3EysjtR0IbBv
7CuHdtRQ50Dz1FlYU4bEOc5iKjdNwnNA9lP0DmbVTBz4yCwpp0Cm9Bwp3kUSwmefz0MAG8OZ2oU8
ttydjPlkdou3qzbN29i1WR9qDJ9on+pQnafZHtUmaG3VbKxX2f2UjIUNPV959Y3ZNGyheYR9asQI
HV4X71pecWuPcddmlhjOQYp7JplHOF0cEZ1tgXY/xAd2i8VfPOJryyWTh9pjd7vsDFTrYG6csnH6
JVbe9WFRZg45iNye5gqVPK5le82pOWQb8XZYhd3ZLSBfWfM6KaPTXGU16YfyPlUXXlgtFVL1grtT
ofI8f3NqNhSreYuEW9WMATtraiUKKksn27LqXKaeu2bVwCCUfbVNGA5pYzFZp1lLup7o+rqYmnYo
vzyJLyPb/449avd7rANrk3KAMiXIczvMXd6ML1BrEne5SFKkyPVivll2tF99GY2VPAad4mCkKRjD
MdH3TwopQ1YKfwpOOAeiknYZLMMwIQuatv0w2DKa6dKHVhgdT+Gf2gLt8VWet5E5UdIXNbqqdi6v
jSF4F6azNN8Lbvl9+iZT/kXSdC5XAXrwx0hCLj2xO2TCI4W85GtKNunWLH4bRKDZvKt1duqWgrjI
6cEnEzphJ09H24faHhS/tG/OjaaHS9u7qcxPAiOtZE5hfVXXQWlRlp6rrJfr1mwyZSwc4SzjtEVG
INVOA1+97P/0+uWLZ38ACYKeHr/e3zuUD/u/f/ys4bXjna12kaUJyo2G1O5oiDcAYYoum5gjM+fM
/yanUo5lGdfkYrYjmelGy2VaJCTVqn+Mqs7Po/E8PbP8w3GwFMokywCWRbEe7p9z84Uq4zB6q0NN
R+BcjIiFuDk55kNR3DT95NJu5cavxt2aRzQR54gLuCtvkzR1C96cuMFIjazo6O+CAG9OmmmX3stg
CS8eEfVMgzGHzGWnX2L6YiNlt2oYmSAMh+VsK8mbmJW5WnEGzZWL52EYNmBn5A+Gckq7sGtohcXx
T1ZSaTOLlXd9MGSo6Y/44KHr5Q4xXBa2rL6w2Kjq9jFGzq4jrA9FWTNMIGLcsPnGLJ6BkmiSfDAL
CQhiKgz+ZeUu1MFGtyVqz/lMkTq0qFPjjVXehA4UN19YpQuTdlspvhHVUVsTWXwrOQyQWRFzZh1j
brbnvVLD0TCgbDWGINdQ2rOdoYQn5qzMn/jyrfyxZj2LOZEDEAedjjggxc37wnKXLZcYKL22ow4c
1WpWXIhZwLgkTQ8szORpu0qDj9lQlVFHhtqZWFEPVoBGbsZ1G+HTeHwOrSRAkezJ6x85oEobb1lR
MfZ87+YGIW0v16tlRCnv1y6c6zmfoBsdSC1jQ69QTSHpPYdReMuTsA2Jy4DFU6E6o1e3Cgl07up4
b7dj0iwUzcw3VnkbOWTjORyzbj5jmqzqZL6/dpFsII4yM/+UfBTcXyWBA2E6IMcmG2hW0KOjCU5j
XvxdGSTz2JZT3W7/rlftylVCIy3UXeZdV/3kwrQpyh3kjCiOmifYBdJlmu+uxzgmaUuKsjWgACwD
SkzeMGZj6HwWN2eJL3LwrXSFrk4wBUKXZICeBcYVuqJCefkFl107w3yNS34lr+ouXzfH5Apus85P
SdapVladUMZyD+lXDZYV6FVPgBm95eIIHURxn+i307DA2KQiwB2HfjAR6aTqucz+zlBenmifuarM
QqH2S9GV25nq6JRLHJkSMuHI3Hyj7F6o5g/zk/Urlxh27Uo1YpwmmaxKUhTb3KgoTT0XUZ4xDFmI
WYNLcSk4P+YTxzMfFX+PD5AdHQqKSE4jND7NX0YWr+eEemdxF6hyHWWSrGwd1mISnwccq1urnmuD
IyJrQ+0kHl6WQoxqucAlmzOzQIDKyVXq3kMv5zbmboH+PermSh9jrPEfo7//9b9lXegMwZ6LwSzK
5qQXdE3N6sSUWoSpu6q8Kaoc5KGt/ENraVksmE/7s7iPW7q6yg3t1KG4tMMRSIxfe1ZYihtLeuZj
vrjEoZ7aJUUtslTQy7NbXeujZe0x/uQDmjUQ94z1yBXNKFYv+5kvRtTXMSRHSiR7W1OzeF4Pi4US
4ZepV/syrWMCC41emOxb0FbQJZYmrHqSFFv6WkyKnipTKBlKWdegIxu6+VRD+Exd0pQnp35USPNN
VXIFku8SWT8KGzAwMXf0dOaXEgCjslAT8PZmKOXSr4ziSrlamnuIFXA5IYnhH/ywVy2emrP7PEHS
6ItGkWQrvQJtlWlTRsw+LWkShMRcj0V0zE12FPVahipVqwtIkruR2ydFprIiEIZPQnI0Cf4faIoi
Tgv3nXPBj7qdjWOznAF9x3drCTUimEmvJRepvAoSvJmXzp3Gcfx2PlVnTFpeKalvoI1DWErJvYCy
oiitzNBjsiUoy3GbT420ioZTugtKdgMjvzIFFGCOhin1AiVm4dDRmlWkmWU8Kus0bxQqry20B1cD
9i3wzvMAw7dBIDjgsLKGI5rzoX9XT+EmzCOmZ8NSK7IMbcrok3SMcBZZRtxZmkAtQaSWI1RLEqsV
CFZGtKTfVr5Mtgq5c5kVliVnX75Ln/KfJP8LXRa//rH6WPn+l/a9eztbd/e/fOr1Jzp4m4Gfy93/
cG+r3bHiPzd2du7y/3ySv1VT+Cy8qB1qZXc5XM4oBpIr6fHF1vXizOSNA3uR0MR1Wql9cnrWNrJb
wYVFjt+4nLYaFfR3R60a9DjUxDpV77feVrvyYv+nvvZ6Q7xm9y/y8HA5xTe83/6WYsZSS54Wp6+L
HHoy1RxPVJwRoE4PH3Z0ruTPouwPxvle/rM6MhJT1z5lR0XVdmun1W5B1XZV9wOi0zwhtQkgiJWY
nbFTDPtUammbKBO0wzFHpo5gb5ZsIfs+hbmlQrKVUltas8Dtp2lAl4loVlkY9narzd6jtXbD2254
wnnIWfq8s9HabG2J8p2NhrfZ8LaMkU04WkEhQl9cAJ+iMi9k75nwcmH8sIa58Fxe1sYoVtGbDLrV
Bp410yuITdAGLSAnrhDuI8YlM5X/YRyoYKnSkavQHADVylFVmYApJqC7axRGPlt1sk6ojmmm4qW2
qyiHD46MLvdw1U4/q+fYXsc+4CT7O3x9HCcJBrOPUnm54IKjUIyc3Gm2v2lu3D/sbHTbbfj//7Dr
cCRWV1zSbLWXRWHlCojz0KIr4rMNzTAqcBPqFWJeoYtQT/yrh5fJi6o1Y0O9olu+ZAF1dGsgtjic
kxh9TCstkNpRTh359XJWMbOgdfrNNXiNHaUVJnC588KC5pE4l3Ygh6OmPH6U6WAX71dpgl1qt/4D
kGHsT06GvrazdbKgUYRFu65dtOtWcje4XgopxZrkcdJELf0wSFso4Ie5VeJLnZGnLscIpK+ZDnAj
2QKVtsQPy3lL0WfrIODD4iZvhWbL0w2ZsWI1kq6EjhXpOh0pAEZkEt0KNNKSdPJ7w3gq8n/smY8f
m0Qq4JqFhFRYWibnckSlBdyKSaleWAP0rRJpB3F07TlJGT/1vvvEGOUgsDKq2E1oxTaQW+CTU8Sf
5yFoH30bwT7VAjU8zRT8T7NaOtG6faqhryGLICWyCRZadJBtaEd0ftIXlAnv1MGdDpqGvIqHceMT
rj+PRDvZ4SVYAiMMRChDgJW2je5qZ1WRHoaUZCHzhVuxYW015D4UVwf1QxBO4ggeYT35wOWTKHyu
o/YomF3EyVtP5IX/T6e+rLzLDIDckDO6jF246D5sPth6fjRUOzMdxNNgWL78HDtn7j9Oz5V9bk3e
UmBeLuqRjnixfi6TlxXv5gyrFEH8eoM9M9JJLEmcBB8U1KuAzA0pv5T8xyNpvaP16rgKiNA8XlAZ
necqWC65oU+eLKkF7R2TVWpzw0aO1kH/6fOXT/bNmeOXGvqd9id41RdWpdA5o6MQQM3LeDqOT2pZ
5N5vKVyvTtWOjhnYdGLI5t0Wbem0ZkWNaXv+pqu6AJmTAHNFpBafuWU0dkw0C4NdOEfFaIxpuveC
MWHToK1EW+5ldhZEfQzxhffpfLxAgrI2Yn7m+V1ppZqwahUl1rM7E2G8Bjj1zA7W58xEX0wJVIBy
Cdro5Lkk+0ZhC0Z2hp72exFpF4GQTrtQtnGxKJc03y9t9srD2Yif1CGs2dwrudDW1PSscFx/5Tqh
yEfWaBkg8qWMOGPXtB11HBlZ8oVymTC0gO6iK7M0xwibA+hM/x+CPBkUb4o/GvUQqTGYRohBXMAU
+pjYVdFPjDH+z0E6lqAcC7nNP2TvqEQqt75zzHO90m2DV7OdJnhrwT/jxpEgvOm2+Zf3/8lilvBc
HhOgh4Pgtv1/Su9/6Gzu2P4fnTv/j0/z97n33I/8U/uqp2EwHceX5KmRnlWO3kTh7LjyJEgHSUje
or2s6A/zk8reaAYKtFBbm3xLTItD5bxJnP48D2ezWOJW5Sc/mqXu0pXXwkzYy1erHB3wr+PK4eU0
6KUh+ldXMIdtTyFx5XtM6as9/wR9AH14EuIpXJxc9vJ5qSv774IBBWz21uPpTMt4fR5E5+snYWRu
Eq/ZZOdnbz2YaYnzs18tULLHMBeK9OvFUVNYXeSrg2DQ267sR+dhEkeYPLL36g+HP7x88ebFt2++
+27/9f6TXqfyIn4RXKg0NmlvhvGB+AzE7XAylc/xDCZ2QFl+0AM0HMzkyx9ijAfCUph38SdkaMjk
UwcIrJl4xcm714nzw2IIU+AxLWcw/PayNwFdJGyiLUiu5p1/5T8T/ZcpopDtfkL6397c3rLp/+bW
5h39/zXT/58ozbt5RYTK8GVlC0qBWiDhOa7gf9lG1FtEYdZ1vaKCA+jlMTVjDXfU6Pb2/23LgIv2
/07u/s/N9t3+/2eR//JJZMvEwVLhj2SwZ+EknD3FW43O/TEKSjtt7cO38ySd9TYrj+NoGOJIbkxS
bHEyjgI8wWF5Ei0nQpSkn5qEOE+hk3jgj7GrAN7nu6u8ee6nb3sY9lAksGWy2a9w/5/dbh+4qYvj
PzqdnTz/b2/e3f/3afb/Z4TQqOOAruOd+LDdP/fKdreHGxf++ftf/w/vNJw12+0tqPGaMo5iUtBR
+C4YNqfzZBqngSwsjrOZzLglzlalkoK62NwP5rE3DacB6kyVip4htVddaYtXKyIp9pOnr0urCrNk
Rcuh3at+cZXVvl43zJXP9w7wpiExpIwgpIaqWK28fvOi/+Zg/7WWGIZffv/65ZtX5lsxzadPetVq
5fEPey9e7D/Dn5VxfFqre1ceXfU28taOcuM/9r5M/xitedUvflvdRf9ftl0Kk1udzJM0QBk2+UWn
6glLIM5zo9u8rnrBuxB9pob0ahNfVVT+M6859JoTD3Zx22vGlF7Wa55Ch2oyVXjI4IVVp5ezszjy
mtkHhBeWY/Md1laTxicxafwpzZTwUw2r6j14sPbqD2vLXDJGRRA26GUgC8hn9k74C56XO64ZW+Je
sfQyNa+yFpZuuvcKPraAm50fdY7rFY6+1hOsqlyscgEaGeAxg4OsvdG9d1yxE8HmrMquu22Lcrti
koTMKTafHdb6nlmKxS/rO+NeaXZYrUw/TGMoJ5egFcUXNbkKrflsUG9BAYw0x4NqvMJQJRzPp/pW
1+WKG5pxCMdZFokjfWjHFTNzuStd+bXV7CiMlB9xabtq4awGMpSV1wCrN/XKbDKlNvGIIZydkbMz
309BiZG+9qp83F6hk2f4yblxl8tfW5K3NoyGaGfacGewLchc68hYW5ypFr4kIDb6AzpV4oso6pVX
f6igH018ERHZ6LppBpEGKjiJhx5oC2372zWmdQ38aD4VFC2ZeM2R12xqdESWnCX+1BOlvf3fPz2s
4HLVat7+m6dPMOlf26vXdzFHQUSkESjZZI6X08wpDB7HiYPBVfPu3auMQqp/dOR9hl1a/Xnv33vN
Z7m3x8dmBypFN8DLEx5JuKXmEeagVd3t7FB3FIo0BEpc08io2QEDEtnLKpTxZhRvejF0XKqIoX4r
k8Tg3ZSS6/ZRMzco3nGFLkPDvMbksML4IxPvCOeWg9f739eAvytfljjJvj178Tv9mzjEJI8zNpCC
opAlgVfXjsCcTudjkAJxbap1JhnYyhyoJmALzB5T00wvYIfWjPHXW9MLLFXU0zySxVXmZMzKnuid
4FC9r7yanMVP379+5b1Xk/rp5eEPy8yErrJbB3FrPCQ3SHGvEvuvIHlhMpIsQ0ZESJpypBJ7XS2G
lo2H4jH1KwOKB0lb7CTQrnnJsIHvu2Du1lB5zRuenmBW42sNKz8584tgxvGEuGay4UWDGoXBeJjK
pIt8eeEgjjDx4oxXCZvU/L2g7Q5lvKfXysvrM83LqxgbsjtkZP9aX1meXW5buX9Uls7VX96nmcQa
ejTy0XOnxtlofrl1SUZmXkoCLd1SUlW3X25uXFd12acu3RSLxioTKymsHmZjlKlijFFqvNg9TpGp
BVN6Ldspki9ohFgwSj357DRAi/XmsXcs+MBr7rQRHvjw0Ntpt4u6RCwJLBsp9EYCvgZh+UasF7HS
OrEbZH+6jK9EGXTQFjfk2Xqb6sir7mxTKzNOn2lwJ6pMrELkdckY0zayYF1N+aIGLMprRt5aZ7oG
LOhB9QtmW9W6psFkpTbypYClmlpA7//h/Vcdgb4APkozXjRfDWdogrty1KgQUTdKvdCcqbBp6wsl
mF6yU2tD5TvOxIZ30I+mNmZSg/FSExoKus4084mfojY+9ucR5RCHzZUXK2BI32RL+A3KFlyvT3yI
lge68JoDb+3LN2v2eDYe4jUj6xFsb4kxsGqihQnriloD/pINMFRAzdOGUiUSSqIXlvws+zwh5U9g
xj1Ai8YW4cXNQTUNEgIVCESenwRlwIK++yfhLO19Uavd/1wfUr0uhEpVBrh4e2NDFy1vsohORu4Y
WsVsXOpIKkYDEeE8SELgcEPviyuB5NcKWyu08UmHwqJaCeuuhy+ush16XSUjzddBxVroZlNyKG0/
NfG0nK1CzSZmQqbL6pFnngeVZND74hGbfAIByWRArsnFEMzUNx2I+aFnvoBelcIFaa5l8/IMBzwC
cxuhvHAFpVUMqwCgSd4iZf6Lq2RwjWJ6MhCwLu2fm87Vr9BQuJGPbP+9dbvvcvbfzXbn3j3L/tve
vHfn//OrsP8KApVdOKlIVWb/3YQaB3wVlCQCo3g8ji9S0CUnc9etuOkuBZDJYphVU5XEjCsyTQlf
KiPChqGGNBLP+R/TUPzqJZouX715drD/ZP/x7/rfPz384c23dHlKt+mKT4btJW9BkTbfrLZG3rrN
QiMvNHHwByj4vP947/EP+2YTonFohT5CMzkb9LqCLLRkXMVCFmit6et1M94tywRrdpq97zYBYte6
LKYVEy/Jzvts//u9x3/o77/4EYD1nVkOXlCZV0+h+JM+p1g1ixifqPDr/YOXz36Ed47msi9mUVfL
1keqsP/7V8+ePqY0r99ptvK+fN9rwyusjJdHwcPL77579vTFPvx6tXdwcPjD6ze9Wr0CYH3F5wLV
ysvXT79/+mLvWX/v9fcHvVr1i3/DYAxK8WkY3p+++O6lbWuP35plXv7uGGR+swxmUDRL/bT3+oXd
EmKxWeq7vafP9FLew682sCSGXWL8lryiDOqIV17z3CPrviZ2bTz8qkOyqGk+AwEMhPLqFxIQVe+r
r9DMr78BMRheoqEtGekf3Ca2OVqJResDEAkfPFh7c7D3/f5a5Q1+6WbnPt5RTKfIKd3hBLt8FqP2
Pp/2pyFwoeNK5Y0hWaeoSYnL5rwnnGMHvZaHc1K/1bVMQF2IbKQLb+XWPZ1R0gA6AqMJQF661Ggd
H3fj6GZnfnZ3dZb4t1XxiI7h3xPtKuj8gAQJY/WCrwyw+q3kb53JjSB45+N11Fn/oE/b941jNC7A
FCjlYygH0BGwRhhmUhpD5T0N/oDuuyKYWfdciSq4ZObfj6wnZjfFYo1TeVNsxj749kGZ+YTbUzKh
9sfrvc5d0UfTLZkqnoBykCLiadXzFXEAz//98HBd9A0sTXQMUD7BM0n9b/8dNOgNQ/80itNZOEi5
qCWsUtEXuEyIdpPpjEvFoxG6LxgNHrwNp57KUQ6rP0foryfBCJ7OOEVuGhj3jDlTemp3Sa7hlYow
w6FABzFGvOkHaKBR4xldlL2ezcfDkI8kHAYtKgvIoVgrYiFill/cv4ZoVe6Q8BdamSUBnoWg5RCn
ot3/KBY5GE/t5g7O4gsoDbXxKyDoTwJ5FFo2NNRJAoATt57dJKndfSkxOQkGcQJyOxBsr4y/Guyz
5T1Fm1GWOYtpaUNdMZ5WaBN5h2dEOvRsJ8JsLBIaIBxpkK/9dHoCsL70XoWtClE+tJhcnKHBv1b7
4nPUaoYxEUdM241kOuQUwWKP1T2NcQHNlvzqa+RJnSpUT8/C0czb3RW1BP7VPcnjOrkiynjESwBU
/4vPveZp4G0oIwcyHm9N3rxOidvIsU9VXpM2ja1dFRQi5rCBc9CICU5BChsbwNZyzLkDQ/N+Wxed
PpY3aQvTsHGhaNYt1glSfyD65iluZJMExLzZBKGia3KmiEETyfWJKPy+eVb3iO2JRtryO8ywdPVo
NkMK2WZjCPFivV/ix0qXVgBkI1XHMBXx/Hh/khCgqPyAjn4QsrCVQW4NhmvKiLAlz7VA8c7wTirg
2HvRgRmaow0RBJTnYaw+I/8axd4auoRkdshUbZhd+NVEx6k5GR5sEwgnI4YG18RlycGAHj3UT/4o
Vsgp5PfQlvjqZdVRypLEoaQuWrtqGOJ19pAVRVUJFqiNKv6VIUIe/dsxOU8AfOXi7E2nwJroqEcm
QmEvCrrhGmdHSTRUPhy1TB1aJQpd1xKniFDnTJJL0PCmaw/ShilyIHVMhwyrKB8f6sY6/ZywQad7
KhV77nCIDpa0Mz7HARMe9Fh3XmdR1A0P/e/0gOqcybxjn45Y10h/wAlJx2Vmvy7ZltrGk3ZMswBu
UANjtBpeRh9FpH8gU3uoD1lWEFj6YCwG8hfdsJYbA43TVOMEAbFf8pV3YWQNyyJ5Vi15Q/IqszVn
usuXVdiT3OVNkgfCFzU3zmtWZEHuaeoaZLCEaibLFQj94E4SfEuVN7jXex5VXedR2gmDkJvUDd+q
lTyjUiZu42xBXjWImtZfyhBLcCy+Jy4TdAThUKKfTczFEPvsTivIg4YghqJuIQCN1iqgncbsNb87
vtpqawcyPEZ13hRGeD1KJjGu7SraIxmrS9XXO2w0rs1V1Y0Fcmkt04KEr34RcJuXu+LZbEpQQG34
r/hNmHEnlIgFHDMxfpTmpsMOdSC9TuczEbsKb/k557eBTMlwcNM3jI0HH+TMoblnZC4Z82QMQnGL
UsxY7+gsznonDNSIT9NY81jDdF4yaZVIusG3jWbEv7utTmPtY+G95n/4zb8ANvVbzeOv161nOime
xksc06oEyfUKXhscJGnmH7dH2YExutkHhhsOCE7r59GwdQpSxfzkay0FUBUdvZt7mLQIK2TJBp8q
jUGYN2WF3zcZIZp707D5Y5YOeaO9sdHsdJobGA59zXH4uP84rj67ogzgCkM1gdx6LSLUR9Wz2Wya
dtfX/WkohtsC/F2nGa9f4T/X61fYJh6ri6n3xL9Fl6BbncEjcWt4Vjmaep02OYAA0k8BqQLnXZhG
Th0uR/l0avUWaFkg1tTMVDqC3euI1/rh8PCV++rx3HKP5GUjWMe7gsIt7OTavmXc1c2b189W7UUT
vLrcG8wtxXut3P3V3kQhjucJTV0IMQSi/3Lw8oX2tr54ENl9ZuKGKYnp2JTeP6EV09c+aC+wDiNG
LszZAP92rVxK2rXH6XrV+9rY8a2f5/EM3SRGIN35o6BXlSuXnvnOG7ms23uVfyG5/lg3BOf9MaAJ
86out9OI5DJ4k8yZX18FbGUXcwkkhibVDVy6xKg5BMiNyqY0AUTxmK6zRVE0OvNPs2u+7WssLWjJ
29GXhBa0Uwqt81r7/VGn+c3xH4e/rf+xVfzEt+CVwvEZW0ktI6JxWabQyqElMXUWmLFl7VFDTfxS
Z9HVfdsR18j4SUE7WgFHc8a9TwKIGVsqm7O4gBeZl3CZMCaWNVIwLq0AjisNlvG+ypQV8uOpyHQj
eApO4wd1W5wz2wq3EAirbyJeiExC0Y6+WegzBKGOVEItoSnvuMNyS5WGlRfT8i48enm3tEbKh9WU
5d+ji5PZLNcEKor0AZkNNU8iURPUBbMKJi25xpAJUB2EcSzLBrmatqzLd0WCndWGJuEt0KiToJHT
qXslGvUSCrWmTy+jTgvHRkuPRszTHHKLqwPq9wrvlxfekeKSWs45bL3VKKXxPtskIlmr9okzDNed
3n6jhk4utU/iWsJVWA9XqS+yF+Du3zVog7pdMvPU0xDqo+5BpflcS5OeMAnnHGpMHRHHKOxMwmxX
fS313MwUL6luRm265L2STegahRDtlTivbXc7G+jDwuo9Xmzp2pm25bD6UpyroL2s683JbCvN/HmS
V9yvZljAM1i7YbT/IxJg89kRg5Ae1MkAWorzANBMCtlR8he1yVvAk6nXHApHTUHSxGv28ZEWZ1Ik
XfbXDhLPovUjg6Xo7kp2fb0uToYUrI1iphtBNomsVmYK1vrtWEZf9mTEI2LVenZqbHUiWzaNDLwK
b2hBx3RUpZ110hkXIpa7JbYPFU9LK0c8Dwm9NVbDdKGQwRqB5kiJJh5VW181AWTKP+Y1p2YvWheP
2f4+oMMyx1TdreNiYOpX2iyUpU2P4QMxniP4hiC30emE0yQ/gHIa5PHRa47Sg2dkPgLO421wHpso
GMyaMoN+B+NuoGgVfWuqX2AXvI3yHVzA1tOXFndi8+eXspZop6AyM1GtusZVqXvZijCGFNo0pK0C
HhsEEdMcsXksHciLNW+qKvXpqxXMAtcivKJYyaYbpjJFe9tQtBseFRtSmerFST4Ow4jKsvRuEVml
CJwp8gEbEPuhV9Md/HQ3C0+dp4tnI+i/voiRSG5B59q4oTN+YfsvpKzFIp1+9fL633L0+tqrZUSJ
+BkSXYqHC1GyvBLN0MGKOET1eCNIo0niXwijCcblYFQFHvWi/UT0up7vVZIM+IR9CePjAIBOvg0m
gTXKAGQ+84wtmuGtqk+UgGlmar43aGJeuJcNe6JPhp7gS/lpyOswFB8XBFAMk86pSEDPRuDo/ono
NNC6ZZfU9CwYj2FTRTP/nRYgUNQtn2out4TLwJpdH7CAopb51UBiP6IpYmHpuTRAVmzBXpUxYMDI
LFrtev4YN9mlJ1wGuBu11bSwaIqJ3i7owcEJhH/NF1dc5Nqg+9x2/FYbiHAbkWlBDQBrIY20N2HC
+XNcbZZJMIkxOz6dt1rw1GmEDlQR8Kh7SUo2+lkGXqPlql3eArQVUI7AqwEbJVSxatZdIJwmAab/
9Epq5YGaX7DyMTv6lU3Y59U+7km9ctGiPrd9/aXIuS4Ci7u5hirq6mg6nsl7p77e3//9/uNuE/QW
Otnr5IiLOEHXD8/Ng26jpV6noFR2MKd0XHfBsvP4m53Jr3gubxa33VZzFgl3NUtZM00bC6os15eN
cEVOBBo5Z3+CUKlThbqS8BYrZMPZxmfJXyfVSwsIgohTvtZC4ox0GSkElrLl78fuUWrCtzjtMLdT
xs+40SVaFPYid4tMTo1NYng/4+Ryfsim9gvPUnq5rlotFO0HewOKnbdwxy25E1ZA5ZVRWHi+6Euu
YQ2G/aTxPBkETdSODNUISZhwi2L8vkvA9uvJ/0ZJS1th9FHif0ryv23stLet+J/O5sbOXfzPp8n/
lqltwTsfM+p6nNx2npCY36p8btJ9DsmTbr8zDt9/tvfCe/rqfAuDpWP6JFy+obHpJbYhvKcxPYi3
9+qphwlIGuT/fxEnwxSNs7P4bRClyITISVhcbwOti4G1KpWjyc+z2XHlLCaFvvpv0G//6asft/6t
6n2uxo9u4HgqEA0p4xQxPRySMBdSZZDaeFbor18hi0LP69y/v1lB3pVOcZg9r6qlAu5UK4NxiBfL
Ubh81XBQr1beBiCWjtFXvOdttitoriTTSn8SRv1hMPYvsQP9vf9OvYcKlSMfU2ceVwLSA7ELCtDG
e1mC6CNM9n77PvY6iMdjyoycti4CYI5Bog9hRDdPTZP4PBxSuo4q2ixEwSYszgAYbXOrCgs8BnSZ
zSmL0dY3rTa+iaNT+WoH3qD9ClGKLP/YVrXiT0NMRcMqNLyxEiqnwSAJQEHXOu2LKtXK2I/wBLY6
SmBlxJ1/ocgbiD2224AnoJRf6m879+H1EKQF8237flYa/0Gfkq37ouDQv0ypkEqYoC6c9DrbJgyj
4CItByCWgDlUKbYYX8ziaRPNTyjGpdUK9IBXaiJ0mI2m/DCIYUfxF5oxaAynsSoZ+MngDKbEj8MY
XfxExeDdYAyL0DdeEp7QL9iv9K8OTkoRdHLJaC6uVd0DNRgPsshKQTUQgzF6eDAOBHxsQDvhteSa
Czhl6/25911M8RcKlKdYpqoHDXD62fQixKu8UqYjs7gLdQt6oSZkH+ZSTgf9U0BUx34wikGHYR9T
pi4sSWdFrlJ3Ysjd393f3d/d393f3d/d393f3d/d393f3d/d393f3d/d393f3d/d393f3d/d393f
3d/d393f3d/d393fB/79/wGq3pFtABAEAA==
