#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — git-007
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

info "PulseDeck standalone hub deployer git-007"
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
H4sIAAAAAAAC/+y9y5IbSZIgWGd+hSeyKgFUAh4A4kESQQSbGYzMZBdfxYisx7BiMB6AI+BJhzvS
3RGPCoZInlZkrrtzmVvLHGY7e0VW9jAie9hb80/qS1ZV7eFm5uYOICLIenSyuzLg9lAzU1NTU1VT
U5suTjbml/Mk/t4fZW4Wz8Jf3Pm/Dvzb2dqiv/DP/NvZ2d6Uvym9u9nrbv7C6fziE/xbpJmXOM4v
kjjOqsoty/87/ff2ZBGE43Z6mWb+7Phe4v+wCBI/dQbO21rqZ4t5Fsdhuje4v107vsfKnnijd340
hiJKCZfyhjM/82r37r3lBHV8L/JmPpacL8LUH/ujd+3p4qR278xP0iCOMKfj7rgdd+yfdWr3xn46
SoJ5xrNeY6WnUMl546XzEz9JLp3XgTP2Ms8hMKK77fllNmV19gabbncLQc2hk340Ctho7jnwrzb3
pnF79kOW7Q16brf1aLPWYhkTD+hgHuwNOlAbMvBPT2QuzoJRnESYub2FedvbkHWcj9Nl3U6P72nj
1AY+hAR35gVRH/+DSELEuQoK54BY79RP3UkQjY/vnU/9xGcTkYwA+x9l/qFTGwB+Q+vmxnAYREE2
HLrzy0+w/js7XWP973Q62z+v/0/xr1ZTVhlSKCTcuzcc8gU6HJpL9Bc///tH+mdf/954FkR3xgWW
rv+tbWP93+/cv//z+v9E6/8JTnaQZolH++6T1882vnvm8M2I+MHPy+Q/5Pr35vM7EQCWrP9eb7tj
7v/dXufn9f+J1v/XIPrCondSP4Fd3wmDiT+6HIW+M4kTJxcOiE0w8WCSxDNnOJwsskXig4gQzOZx
kjleFMUZMZH03j2eFsanp0F0Kj6zaeJ7Y0wgGNnlHH6L+k+iSw6bS+Mig/dQAOHiOC/rJvEiAxmf
ZwYRVA3DIUu9d+/e81ffgAzD++Ge+tlz+OknjeEQdZPhsAllRqGXpmyEh4SFPgn+Y3/iiE2wkfrh
pOUkiygLZn4fO9t02nvOyzjyWWn8h4VcXgZa5b/0bFhWkMXH1MiCLPQHNQPPtZYzjkfpcJGEA2wB
GvYhQfmOQb0BFMmUpmxEx0BDtCn7npccxdEkOIXOcIy6+5TQkAXUPre01GmcZgMO0GVwXOIabghb
iR/ppXFm7KUxRy8LMzUM/TM/HNTOvSSCSavpBbzRyE/TIZQbfO0B1vLcpo5oTtD58NjcNlgHjMJD
RppQWtKoe0S/GsAggGwGCkyc4paD9DNQNFtPzJznz+JocJQsANeSkJDPZDQbFroBInWDaBI3aodY
DBfF7/0TRgsObMrTLJv3NzZ+lfZ/lUILKplZsV9RAjFuH7vLuqj1OZ6XdVlFRzqNF6D9+xdBBgjE
gefUONHbCNKhFwZnfqPZL5KZKPR9HEQN7DqQ8GDb7TR/FkH+Cvv/yAM+Ep/eWgZYsv9v9TZ3zP3/
/s7P+/+n2v+RKwYj3+HT7aANj0xsuP9nU9+UAYDvnQWntM+vLg6Ubff3kM0w22HK+jHk/WC70Lnv
QReSIcxSBrvuOBhlb0FVaWHt45ZWBPbDk9Af952TOA5ZVuSfp1VVKb+s3jyJz4IxyALABnEXqWEq
bLl8O5onQZSV9cx5T9wSatFurVXQ2iNJgDYxYrHIvt/qoI4ZnwRMv/EBwRFuJFCfz4U2WYDY0J/5
0MoYsD925iHMAfwexWHoj7I4SdmEIbyEAXsrmfCVxo5rwbjWd2oct8YOXAu9Ez/E/N/b870zLwix
l1AGdwMjm1AGWdrkomjW4FktpzYOUkJTrWlU5uhTqvMUo5yYPuzmKxCWeFedVzAt+yAfOVtux+w3
6MBRisSJlb49Onp9WBjZIptiJgrM7/xLM/ss8M/teLtuVWMaiasUzS8tmSviOF8C6yNYXR4V2P2G
uoc7vbZunAGsmVMal+MDibNhAOJujvU/tJ/Mg/ZvyvFuYHEZ0uej4SkIceX0/XrfsRZQkW8IoRr2
a3wJ1kpxbKutIDdnH1Z0WbI5riw5HEl6zlIUMa5VjiF7/orU2dC4qAM87Oq6uT6hGqy1glYPnh98
8+qVs7/fq6TCF789OnKeP3lZuvxJBwHGOvbLSLGIuGWoRjPckEnUpeh+AWUce5l/OJo8/lnq/6vK
/8yAcHsTYKX83+3c3+r1TPl/5/7P8v+nkv9xx3W4EU2I/MD62nEUXiqyv6cfExBzm3gjf22T4Pdp
HJWYB+OUAZqD9BQGJwLKa/gURdLpIgtCaU9E69oNTIktB0d9cDHyydmg5bzxf1j4aYY/gI9Fqa/V
dhOeKs2M3x69eC6Ktpx/Pnz1UlbkZklXFFUOU0WWIpCjxCJKonx0kCQxSP5MJSJ5ahQGINK3nChO
Zl4Y/NmnZAsoLnQKaIrQu89B8E/exqkf4wY2DOMRnyIJk+yCHA5TxJ4efP3ku+dHw29eHvz+cPib
gz8OXz85+ral5WEWILck99Xrg5e/P4DkgzclJV6/efbyCHIPD/bfHBwNnz57w/IRL8w0yb65zGFJ
euqjCqlmCAwoSQyrlDDEEQ9n3hyJR1fTSgsItcNaoClwyCl7SP4dApXPX30Dg3vzu2f7B4do0h3B
rKAhU2KeN566fuifxvFwNOqJugeUAoKLmEw+ZD6Z/gWszFE2/D4+GcI+HWVBdqnSDKSrnygMLGSz
i/kYxS+5KL3xkCUNhTGZlW85sEoWvshM2KLhUIT9gEOxKvW8aOqPFgl0UCex/VevfvPsYPjyyYsD
PqlPDg9//+rN0+G3Tw6/Vejl8ODw8NmrlwYVidSjo+cswY9SZEawamn1gbrG0qdeOh3OvTQ9jxMu
K868d7IgS4E1G0wujWI8URYUs53C+vNOJQI5ehQ6a4k0nbpkMiAEFHL5qZMYb2QhmdiTpy+evRwi
C1rxfIMOMpDvDn2klgabzT4y8ZYzg9FA58nMQUYIjTX2VWuBlsOhDJGHDAR9jP0MpNABhynbRquu
xOUQJ6BBTUGTrIEsucztwby14vS7BCcDWm/4EbQLIx7UFtmk/aDWhElIgnmDmbZ96qTz6pBWh+Ol
mKI04AWgj6oY2e5sgqrBbCowFbSAQAp2vMSHVYPHSgEmwNIBPcShCQGI+fDID22Icm6Dr4p+vqco
FNh3Ti5hozXs6Vn8zkfvNV4VGHD8LgDRCxUhdVU4tRobH+ra0CtWDwaIHzpxNihPa7tZhYCtThcR
AAPAobMNweHjgiGbI50t2LY+PF14yfgmY7YiTe+vGKpAyxRmH5kj6YcX7fzkZZQmE5iWzwZOrVur
HiVO84sA2gBhgcN1aAwcs3ESwEJS5kJrlOXyongGVlYQ8/K54kDRJkeV8AdLcxNGtrUN1v9J7UrA
WyShm46m/sy/7m9sXGHF6xUGt5/EadrmLYoRJj66KaoTyVgL8McxZz4NFLr6JGuJpcmtmJYVeuaF
C7RuYp0bLsrCcsemVGbD2gDipgzRbUBdoPLIhnoiC3JTPL40jbE0HNiFQ/+tLg0oY+RWVtiWEqD/
/OhWnJ3x1lj/vHMokKvwiuaMzTMCEGktAdPlKYoVQ7NM4IEubwVEb38Eu257S9HRayEsuGwx9rVm
ZGLejkhSGwrj6NRSWaYqtUWaXp0xBNpSDBBqjgpGSVdB4Zk1rO3hJCBDBcxAQ9RRs3DeqwRHrXde
dGogBQ+NFYREp2p5nj6knRioTKtbyMzhmFkqzGkMy/XSDtLMyyEaOSrAMWyjJfCMrBycnmHpHv5J
bX1jGYWOUXKxV2PvMrX0iJLN3mCiCoFzpCE/3dXAmHk5LCOHA7wuMibJH2CFVgjqDVjDGlP6HTKb
VYWFrU6HeEcDyjUVaYCpD7Sk0ZEgHxin7HxDkKWClPZuOizCXYFkjZSk7mjkN0Q5aq65tE+iIWe2
AKZ/AiCxHm51KCMswpD3AIsMZCcEk8aOlbbNDpTMGmTXt+wltiUtBy/nSLBEOXIUFpaOUT3M4ccw
iEYhqzjnIMEItQ8zBCduqpuL7EML64vdJUMaExuLLNI3lEjqppSW9b2GbyOkogGKCzp4Q2mYI2cg
RZ1892EABMdpCHkDF2Wei4shDCK/UetOYa10NdEwX4WZZ+JUNQNIjucIGwe6BYEQHyFl0l0LHXPK
vhe/K1j3a5k/m/uJR2agEWSr/XjbOWbrAQup5vwaDuXPsAaUCiKpyMVAbwYtAjlQ6EcNlkjwJVvg
00kKGJIfiikN7TyXpg5lHU2/sRs5lAVbPNQqs32IPoiKQzLhWzohVSDeB+U4bflJWlEswlLryUSK
dWUNgYhsUArDSzSGJwWbnIWLJI1Ki+wmWZXVyXZNXsfJNUeJoABcOTZRw8C02WHO5OzE1Px4EqFE
SJ47iw0JjhJygPipQoNNM7nUKrCUvAZ9q1VSWE4jX9/eRVpejadoUlUMBGK0JtIUGYqlaBVhjk5j
s6ZIVKryJK23vpeMpiDy6P2VqUqPRZomzsR4F8uQZXiaIsiwFLUi7PYhyMhDGwAzT5lvPUcFiDKE
BoUS8qokvCA1a1wz1qrAZ14hiwvF15WT0zjJhieXBimwNJUUKEWtiJIGP4jMa8rEvKpIUuvOvIsh
ekCOQoMItQyF5JVkFY5VcrbIzDZp+S5l1FKlp8CeVhNqy4zXP0u0H1milULrR5BpJ7UrU1DIAcqt
5rpc3H1Jp0jry7okLSiCrioLLJVy2a5XOKkqE3HdiZ+NplyWnXuXeMyABK0dayEZt/Ies8JifZPB
iepxIhTsgO/4uLegLRykQskSDBIQ6S1ytePT3aHqkyCh1ZuFuM5EwVxmxYwawWMN4QRbIEOFFqGL
AzfNWkvkZ0UAKJKApdxQuIasQEAqR2K9HdJQsC38q20tmReCpJ0uwgz5sIZ3PVPbxnIcQiXlK5fM
hVjMzkHGdGA3hFlvsJ9921FeOQkWcEquNAyUG4zVvT4JzgitPJN9a9pFmuXZ+KXii106oPNShYvz
wmauJipIUZAXLjgp1bjjDM/Xr0TUUNuJIn+UDWdBBPgKvcu8rCXTXhV2yfKqItNQn/Itis8WO6bT
lAtKsSkY3KGVqRj6ga1SUtE3eDLqZJR+vEwD4Z1SC4EcMgyQqVxJChDjJdcG/hPPeIRsRynpNb/y
QB9DHI+22/GMfLfTSgLf1a9GGHDellN7s7pbxyW6ktoA52TLd1JeKd9JI2ByiYd7uGDnvINp3+qI
jEM51kQCovi0b84cTgDDKHklR2P/ouUEoPTjEP1oMUMDgT4Kpf/F4WJVzlP1SyOl2ykH/faKGr8+
Vgcdn+BZSK1pTBcjHGyKy4pjpUjZFEAlLkzwQziZLASKG3YYKFcReaI4avuzeXapq7jkzCC2zzEb
QKED6hi86LIxmvIDTWBqJyNY6KfT4Pt34SyK5z8Au16cnV9c/vnJV/tPD77+5ttn//yb5y9evnr9
2zeHR9/97vd/+ON/6nR7m1vbO/cfPGwPazS/ABAvBaj9uM2opfVpEaWLOTJD9GCfeujd4CepoFZG
hlA/XqS5Ys8YAE2g3iHl2hKKc8IeICAUODgTaTl4VaTVjD5FhxVnA4U5re3roQK8pnReitU50akl
tZm7rXi93jQo3VgmePP+rSdl6/3SuclbZYaOLTL9PYXRSYaFFxT9aKzfXNSdbHPpQJudVrGQlBTy
eeFJrZxgWIpGJsw0l3vumA7LqpSRg6YEBTAdEBfBWoGVSCUKBm21cokk70VunJIdEYpMoS90sdEC
l4sxOVBKUCCyC7omuO6DB5s2cHbBR0IvVCit1LIWlb2yVCl2slcEsqTPisS1ep9lpdX7LKoU+7zZ
Wdrpa+Xu7F1bMuMwtJ9f6jmKhVhN/6j2mGy6mJ1EXhAS+k681N/ZGpKTinoAUVqoFNI8Ol0CRpYo
hxFcwOyVA6BsVa/hsmlf5YcrmZIqPB0/jjXpnnJ9W5UcTVVAlx8V6ViqtEJOVa6yj31ls2DgiULK
VDR196LaBTFegWsxCC2Fqw70rdRHcHCYpDVvNR7p6qLc7LHyivu6cktFMxkhVgVYTgSKxnRdaj1S
R9QycK2cd53kCmOFTq+Bo32r5RhLlhwUlx+yGp6xvFENfgH0wOQOCkh5D97imIgmj/wElgNpdDud
XguvLiliZhJ4YV6SfQ9B9znhKuskiLwwVJemaDwWUjsRFDrQtIAAuYALnB7PyJgJZhoQAmy+vw3W
1+ZapifGD0pNKGwQKGTQDzWH3D9V2Yp7DPNutJwc+ECCVlky9F2rDt/6dskBGZJjEaheguGJkJYO
cqQZhSSHlXeoCqElDNuIaJnbJIZp5M3TaZw1CgFCbKTL3WNRcRkm6DEb+Rg7kSUKEK38DhmbRdBt
0sVkElwgf+Sl39ZYUu24L6DS8ha/6Yowg6vZOJZp+Jw9sHt5ojTX7aGIhTnbrTNFTg0yChvCRAxv
Q+U9OftkUxGEQMwCN2iUEUgg5g66FoN3vaGWV3QT7qS8AgBOw3lVXE4r1EPKbVq7jWZkyyi4FMQs
qsyibB2sbj7OBwNg9VFZABrDLoKCXgMcZYgWICoCcgimUUTfp4yoHhkTNfJLnDLbDw3LvIICYUA3
TexKEfWSaNOm7Yqm1UpveYVjpRepX9LllEdiqakDrhqsvmaESkpfitZ6E421hLmtZNdeyb5dZPEW
XLOswomKZd4ksVRqn2X28MKNVfprU3/VJa93+ZadlPsZX3E6NHnZYSkctqvhWtMh0G2cyuoFzYyv
thI2WyDIGIgAoxwU1h6tO4RksPgVa0JOgy8RKBBH6IDG7IAslSy8KuCmFTKvqMCNLu8C7tg/Tbyx
3mMNslzV68PWGYLOOdShTSZsbCWil6BqXsV6VFQ9y5rXjdRLckUQD0Crt2PLAZVR30CIUp7NjVI8
XczWnDqr+mqoruK+SYl0xH3b2Cacn1OXB1ARAJZJPtRv2uhb0G0Q/7H/KZmhJVIxgvRQ6gC8h1IE
ZH1qumj2SRtN7WjmfJiffBN0Y9vNxSSW0ufHFXj8lVcusbwqJWw7oqbKGO2gLAD6o4u/UxVQU9/i
mDWAiuKl16c+alfGfY4iaFvXxXysuhFyObcvJqdYAhSnAF1OFbyyJKuxcnECdDCFefMyvY6WY6v6
Q5zqNTDBVvAEVDzu1xaHDaUCz2ixSAtNW90UlCC9FUqxDoUTjzylL99JFI4k8C80GhYCHiO4J8Eo
bVToLrM4ucw1JZhenkTqFXx2Su4LaeYeYEeKnUcsPGQduN7wLLFR25gn8WgDoGNovFqz+qLRHPZ2
rJ6axwt475PbNTGflWzU+rnLtN7Lt1ABuwY9xIUgzh14vebbznFTIeICMhgQNmUv/NkTGZWj5XSa
zsaG0+30tkwAAnVG5SNMLlbkq7DBb1K1FOucMna8bslUviB9hzoD3Zx38Wu4wKmnS2clm5Q5sOEM
BRkztVWowFRstTClqAwf258kvj88xVJJvIDFj4kuJjobTgPH+etfbzZxfsyKDL5Zk6HPWlVo7EZU
TGA6/TwYQEVUT+U+IrFs80pxw7yMzMW1f8LoubNgPA79cy8BXGMIR45uL72MRizAIr8IPeSXBy0X
KfEi2DACom/2HedzjHMA/QxOozjx30ZxG3oOKeM2QDtW7VTMlR/Un3MvyHIgooFmoay4v/i29of2
fgzCQpS1jwB0+xXd9k1rxxQDLU6jYDKpVVb/OvFmRr2nBy//WFXpjT/xk8RP2q/jMBhdisbaCU+v
qrvvjaY+9TmJQ1kT72T7ldX4IA/5HGhNAzq9RZi102Tk1DE2ZX0XdtTL0FdSnPoiSr2J3w5I5MES
9AxEZRF+bqMBnhC+cAvHTqdOPQLyq9fMC5KJjDAhCYwYxUatJfOGFMp2oIanaMpwnnS8a1y8VuCr
18qNFrx5sAGIC7NpLQfHEsp3CpWzKAZHp8bjYaDTWh4b41ppdA7KKW8VbwdvhHF+6zZfPJRaWDHU
HTH2vCPcF4ctB3HFFuWYRlPjmHhBXb/KwBMLii9zvrF5+pVccBChBDSHESPOgFLKemneFOlQGk1D
3583Om53u7n0XAAveT+LYJtBT4v8nnutaeMdaliThjKF1xbukfogEdO1dV2SKwR1kDufEnKhod76
NotdDGGvGhSiO8hIxMBXMVTNoBhmLIVllYIUPqjhHj7KjFNVYr4FSy8jhGw6wHVlCS1cvhgtVIsn
kvmCYQmrUuyqF+RvMWljP/QzX8ybFmlAoOAmA8+XjLFiR1MvOvVzYrdiooyVLIk9UIKZVdZ9ca0q
a3ulsza5prCigrPcebF4w9jAEo9MoxWFb1uxYn85zGrWIgutwllKwwvwEUleGaSwr9DgK3sIQ1nD
JwkvuGlNKJEoStVZUgrIoUqL8IJN57WWn2evf0OCeuPPMKy7JWbJeZBN+dFBo+Zms7k6BqjlnoP0
4St6DQzhS6f2J7y9VNBzcoNT6o6ms3jcQBCgIcQ7nY6Wm/jz0APEs/xiv5oVe/S1VQDQDkh4SHN2
xHeTVbwCVxOmeGF2YQKHKw0tys6thZEcLD+fK47eiEtoE1GM2IWLOQONvjh0HRX2qkaHVFsKXk5X
WGFhOW02krfMgsgMC8dmNEu0KQEMi+WDi4yaYVC1QMl8DK4O+3Cjwu/MMAsimLKjAO7OZatRjNrP
7n3hfjsHoiupJvMNA4WBCRE8ty/QJhKOjYJ0I1aWoq/jQthKdoJqRaywxGrUI8+IWtaZKFpbjdqW
MsflxyDlcMwCNiAFU6wBw8g/rsY7e78AMFVjrwgUZ1F/Y6CEQvJnBswGmIkJ15RpbFJif+avD4iQ
WcyoVa1nKLZG3hteG1TD0Tt8osDCNFidtzVuG0AKo1BaZeHPGgWuIYyaNnbJQCjsUsT6+shck3fN
xJ5dXmOlNghLxa5S8qeQ0komDaiDYpndbnB8EvHdDCViWa/TK4yXl/wUIxb0uBbF4sE+T9XOvyny
lRL/d6ks8xBFrJhJiAHIGyIAYCok1vDSyeEp8uwUQwejpVLvB0/XJUBRmF83uKqxyPU1dheldr1a
N4+mJGHSxLCoZALuiKKLom866/6YSWXy4ZQqWZHiGCK7sAU0bPAWClLj10HoH1wA+0vXEx0fVoqO
BXPuG0YQReOutUF8O4Y1VPuO9gwni9mwcDs4gy6fyhnuO/R+DHZkSacpIF5Fp3OGW1iLBf7K0Urc
lSF+HT7KQ0hqgidP+ocUPeV4+1UPYxRcVkrFJJW/6tHMyl0vKkQqCzgsVg7LVrh4odWKzqXASg/G
DV93u0KjBLdBqsJPZbb++qRlp4+RN89IvKSDS1PZ+LRaxZ1L/FdVDkPrUnGNm6z7K6yQmjgPRfG0
yidTwGhWD4nrJuuMp3oZFQZTtjhXHgkBWDKMSv1pfX+V4mCWs8tbjFD6z5YO0s4YhGMqG47CIvQr
Ex+PR8yrrzuXMwflTQy35DUM417OXL93Y5QuXr2ZmxdrjBq5Mvq2MHFX9gtQy3wc1/JzXNnXcU1v
xKU39Ve4vLbKrf0V7pMtu8FfeU8wt08Ix5Q1LrdYFuN1IUX3C58LnzOt3PGqS5CvAssa5DkfXZFe
QaCzap9iBBhopXASImBi5t/FMYg4VDBy1fgI6Ie9xpGJIBGrcZ9fY+fdRqjU3FvR1LG1qLSakaqh
vUNZeo1pqFzELgt5YUifrWW+ajlXKR5KWplwyf5ZwZlvcDGypJHye5I2nq5gu9ycaE4O3oMy7+69
7RzbrsohkSrzo17hU6/xc1pVr5CtRHRVV+Lw4RPOUdHMoKxbqwlBXgaz3nkzrp/lw7dePCu+A8tv
zJkdctIFgPXH+H4gqfIW3OiHtdBH09KgvhxRalLgj++W92TiBSHH3K9Sszcr2hh65fdEy9ipJpMV
GWrqnfn/Ac6Vc242rLqVaedpUkCmyCv51ZQ4HA/lm9A6txgui/SuAWFSBLZ+xaLKl4SbZ+FvKBYH
Sgpa16/LV56o1OIx4gt1het10SdZe2+joQDRadX6WkfDgpJCrDLTUJH4dJ4gUL/Ccic8MUsnLAFQ
xnGpi+vAjbQJywwd9AsMtVkwV8qnOqyL3OoObpt15Xw6p5Cqs+nCGbUVcZ14Z6fTtEqPrEAefyVS
qap8cmWslDxuS/FG91IUmI5A7gJP0d41mqUlFevwyzj7Gv1SS1ziddhpai1QvJO2jILFiJul81lJ
hia52Fz5jb7amDndOd/XCJj2aEHEV+ipSrzeFY/TXNcspmWrz6DQA1axGFRrFPK278ZVfn/42qJg
yIIWr9y8Zn735HYuXEKiiS5zeQcv1OQtrXXhdoX9ZQvQ+l30LorPI0e/acwiH/CHxZS9IOeHPC83
WESnFNiApytBKyCnkY+Bx08UoAuRlUwfSoRrXcZlA3oZ59e59fOsEboJj4sObdJZbsQcggfQJr6K
NA68IVLsoBbMvFN/Y05xt2yUhS946W5+qfVFnIQFQ+DPSbMjyTCYBSzQAaT1Op07014DeUzCTgeh
NbpPKxL5qZz6JNlqIokgGXzriwOrrXimwUIHkHhceubxliPm12rPjgtvlWZJwIKe5I+oNQRshtQB
/XfpIQC35xZtffrzER/PzHBe/drMKra+c3fpy7fnJWcu6rMy5/LtGLOM8nzMef5ETKGU/krMuf4K
TKFdikZ9TmGnjTzLCy3nhedXjDrFF1jOzfdVTEul+cTKufGCir0F8YjKufZKihU2fyjlXHkLZal9
9XyJfVWEH17JjneuRysuWQyKliVWA38bsqBmiUXB8//+TVcsIH5T95xltiSWdbxWJMfac07yDtUu
sW6tEFL7kwS1LjlQK0a4VnCsxbO+xTsty00rqD8W3ihtWOemxW75yeA+9nGVml64AKy+i7Kib0eZ
CaMgy+ahlPmvJQvQajUWq+/vxmp8V0YOthLKX38TpgyjU4XAWn2bkUxXNGTMA5liPmlDwRosr9F0
rlcxFtrfGGJDBLKr1cpMBGItyXdJdHtgbQ0D4B0SeiURl9jqBBn/h7PV3YCMl5Cw1YKxLo2tShU3
oIw7NSsK9N1uH1OfA7I+6lC+iosXAI2tW9mE2T4lckqkiKJBR/SuZQKwGihNHeXmBkpBLcu4j9VA
WfvHMD3iS62czBTDhN0UVzZrHEAROMWiEeVcn7xIy4yYslip6XGl2fubt+vZNXL0Syqq48rDNx9P
F48qHjpbRRGPliviUZkizh/3iugVLyNPPOQVsQe7TOuJfLMrEi9zmQq1fJwrEk9wmSXyV7gi+dRW
wUqTv7YV5S9qmaqvfBMrEk9nmdabwutZkfk2llGDP48V5e9gGQXoKaxIvHplNzVENlND/shVJJ6y
Mj358tesIvlklTl3+qtVkfYslVFWMThE7spuV9FdmgWiUrOACivVgVn8HHBtQOGVWyIpy9WeNRQg
ql9TtIbIOeU+ljdu2/aOo/70Y3OJeySyFHy8+Q/tJ/Og/RvfDNxdyxIvSrnXWO3bo6PXh7WlNhji
f1b9j3jgz8qf+sZliea3qpXiNi9v4XGMp6tjq/mLWJ7eolGWyV70uleJ2oeOFy34n3iwih0Qs7b0
tzj5S1FNPVd/CKq5hhKJvfpoGmRRBjBWwc+6Y9UqkO4QrNYaSguw0hLNpVotRb1SbXVlNdWyDip0
1Gqi+2sqqKurlZWqrHwN8u9IC9VE85uroEQJlTywzDuGHgQtsu2fldK/qlJqmc+/A430F/+h/k0X
JxtpMtqYL0AIHvujd0NMoSv8GyI4nTu/vFUbHfi3s7VFf+Gf+Xenu31f/Gbp3fu9XvcXTudTIGCB
MTkc5xdJHGdV5Zbl/53+q9VqhzMMXIwHbKGD+gyGBONnmFM/nPtJSpLua6SQp0Ah7HK1CzXv3aMV
NRxOFnQ4MnSCGb3xRBez2XndvXs8jT2gI74wQk8YnMjPmTcSv3Gli99xyppAvgPFBXwMDyqKcK9A
8YkM6N69e6+/+s3Tr3vDZ0cHb54cPXv18hC9a7Y6Q6Cve0ooMUjt9pxfOzsd+s89FgLv8OjJ0QG9
5jYQkUjPvGQDOpCvE7ZGgMkXI+tALRPOhiPjyLk49No9M2ykvRIXSV3ce+8p8bnQfyhfsrxUTYRy
PdnZ8hvk1QrKMT42pIf841yPTYi7SEKMUEiVKPoQq9l0EyYrnNQGtaY7pkC/IGOkoyBANyjZ0li0
JNzgqMUlLXFwzH33SweaAPw32ujXylp3fuVsNUUzejgn8YO/GfNrelqS7QKpcKQqTL+OAdj0sCkB
qek8AjIwXzTK7903WGiUPCAVvYnHHyp0vAyAeZAAlKS9U8hC0JHKJ1xXs/idH7EHoBrdHW7cDE5R
oxuINeHOT96NJ70hrolGLZ16ve0dfEVN0A+fJSFltKgNFQlaTNdJjYNjgH55lZe7/uUVIxUE0JRf
rD/Na0FOZREKOf55yCpl/kGH6BdDAHvhaQy7yXTWYpFbU9ZxkqNaHAn0QWFWCaYRerf2S0DDpv6g
pQBKPm7aSGvWs14K9pdDkLgQ8X6pZ8pdbTZ9jM5ld1XBck53pGUZZRza+1mNnJpaDoZVNaP1FvoH
ZLSgmMAfhSwQCoifs7kHfJt1usFabMlBieV36kf0YGtOAvpq+tzpPoA1E42BURNpY25vy/nuzfM2
LnhlVbRATnNS2FbCNl7KRLPcfBFhu9hFV+2hvmQ472h0H4heWULxsrsGr5kSVojLa/AmEmVx+FHm
zt6Ng6TBPlIWSNIhYXgYv6PPZklIa3qRXCiIbFlr017hEi7q21jDZi8nsQkSF2gO8Zw4Fonzqftq
+Ps3r14+/6Pznn3tvzl4ciQ+Dv6w/7wQEg7D0GH2ZEyQJmO8y35So5giU5i80NApWBpTdhrKFQnO
OzmbfuRsrsA4+SQJC5oeL5DPNwHkc2vEBkUE8Z2M+H0UnzNGz96LA/wwl4wsC8UGoOzxButPUxb4
pRCljaw458LbmFmFIcF4rp7xSAqAP17M5mnjqrZA2y4TB1p4uDHHsAysmS+xT9doWgLi8jC476BR
a2Gxfq3ZNNcs3zKC04icTWRrtFhBm+KoaMnX2EV9viu3JK9g7AG2bbaym8aWcMUBXLtXsjWT3wv0
E11yXr/qVFTtA/kDBco4qRHB5l09MrvBY+8OHYrpzsYOZf8UjrjCnoJRRPTXFNjOIN5TsAUHXYsW
lZaxLWb7WcBCxiMNRobmw0l5OaTOZou9q0ePDELOW0o9dvbkM8qlO9d3UYAoVp59aFkfgyjb2H7x
87+/I/0f+BU+DHZL9X+J/t/tbYOyb+j/UOFn/f8T6f9PsngWjBxU9Cmw48jX9P7Uz/DRo5QHbx4D
86eb0mxn/+7Z2oaANfX7xJeqvT+bkyGd1XG5+VRUQguxeFqUX6cUn9x5iX3CNjf8PUhL37KH21E9
RLO/T/wfwDeSWuPxLG3+5z+9lReV0j8Jp7I/Hf8pcn/9uPF4APnv//SfmiDF0HH1OrDQMmoFpDwo
vyosfrdKA9d4/Jm9kLgdBqWPm7xRrsp7RAZDJu/lknTL4deicnV7Rg+2iqdZc2v0DSRqlEJxWslI
i3IAn2KojwFC5/wtpcGk5tJNYgoodY0CAoAfKA1yAZ0HYUabjQRrkd2tsrAt3PJKwjFHUNNWYhIu
MLj2PeMYYIKHmQ1RBl95jVWpxAjujAiviO2cHxcV3pQtnGlQwOmCAX+1C6xkmpfvclEP8KgBV7dG
MPAbaC1CT3f3NftNT4eS/EhWf2kryImHa/4rHbfhvUAGlzshNUjfVoYtgbFCi5MGb1pG1mZmBzr1
HnBhU793y2HgH2EKa7LaUB9+cIDsod7C4hEN4NQN+MkOQx1QKx7GSx9ojkDGy/o6q9JVF3rdCB8q
y9/EURa5YFDHioPJRLim4U38egbLrs7uX5Jnm8gj6bI+QQGtfq3UrufOMk4NFwpvoQ2Thg/KtLdq
dVb6WEwLhyyukdlPrGgc4tmvibyAhn006n+WXOdTLvLE7bPVgMvSCnSRloNntWDGtJfI9ABWE/2C
GwJU1EAJW73xJowUpJCwhyaa14aL0KSmeSnpUPHUWoRV1jy2ilDQt62kT5BjqWDep1MwZGYVKxs3
65S6Rk6xqn7HTqmpZ5S2Sdftig1ScllrePOu0BImFisYbnZKLSNHrcoWgKZlI5txv4+DqEHExXlH
TecCzJXFYAG5IGO12+eASwhV4wrYwnFhkLdhCwyCwhssJJd7ThUqzliQH0sl2uaKFdhFOmsN5gy7
2irjjrF2QDzTtkqYt6y9Gs+0VeMetCX1eK6tm8KrtqSjIttSlbvO2ivyTEs1w/PWXt0oZAFDMrm1
rvTZtdTKYnsd7sh7F3yOe/WWTTxlWqoJT197PZFrI3DF9VfhHmpysZKFHZYzwhuxqLvZazijszIz
GYLJ4GeaMraWSMMh3p1IM9EjrymY09L1KjdCN5C2DIGBU8/OQJl9X4FQXqgK2Dw6XQJJlqgEE1wA
osphULYAkL+Om4cgEbyFKZWmEGaKU8Wdiia8ZnHtfmuhAtHM8bGlBqygsUHPeWS0a2sFFkDUXonl
lVTEkyt7NcwpqWSG0rQsvtKgm3aI1nWgRzGt3MPFekhoMEpIU3tBS9BSpZ4ldykYEbTUDkbkmmCO
7c/ZlopbyvMOxm05w8hRon7l6oVV6W05pjGpVa3iSa8Gi/OkrUeGNLi8O6oxqlUhaJodMYKd2fpS
5OTLu2OYtFrVu4XZKSXMleiM4W6S94Cf5VB+0dG1eDbJYDNnDv6QhD+bZ8L/2qbUa7ClLUFV8v+B
7P+L4Nam/+X2/979+5u9HcP+v33//v2f7f+fyP5/MDvxxxiM5PmTl218SdN09XNooU5gbTNbf/5O
LNqn6/X6o8/G8Qhdbp1pNgv37j3CPw6K4wNQC2p7j/DN3b1HMz/zyBck9TNh0OOpaC0Z1M4C/5zu
Sgmb86B2Hoyz6YDtDm36aAVRgG+WttORF/qDbg3ay4Is9PeMbj/aYMn3HtHDvXv3+jiHIOqEcQKV
p/7M74+95N1uu31y2v+8c9Lxu5vwMfciP+x/3t3qPuz1xHcPErxed7MjEjahBpTvnkACmvr6n/sP
/fFkCz5ni8wf9z9/4D986D2Eb9yQ+p/3vM2trS3+CeDgq7u9A9+ncQyld3rjzQcIDOOu9j+fbI22
d/DzxIPMyeT+1n2si7JBBG3d97zeZCITANzDk5MHlJJOvXF83u843a35hbPVgf8kpydeo9PC/3N7
W83re7++Ookv2mnw5yA67Z/ECfDjNqRc47xdnXijd6fkCNU/85IGYqd5jdcArmZechpE/c6urcgu
IZZ/kz12dwKz2MdubHTdrW2HPfrVXgStNnpq+22W0PoKrdEvvNEhfX4NlVq1Q9CPfee7Z7VW6kVp
O0WfhOuTRZbFERDAfJG1Uh/lwytqI4hgnw0yXuBqtEhAr+vPYyLca5ccjqD3F4yC+t3uA0DLLh+O
t8ji3bk3Rjtzv9ebX1yD9jm/Ggcp7GeX/UnoX+yeevN+D+t8D/wimFy2xaEIPW7RPvGzc9+Pdr0w
OI3aFJ+yj/PiJ7wRwC70bEbIuHZP0FnKmXap8zgNfr8HGbtIGe2pH5xOAW1uV3SwI2rMxQzgzHac
joZyojqGcwayK4YCREIncMUhPYBGi32+diPvrFh4BwoLNG3Db4UIPu8Cz+6Odxkp9bvQvTTG60ys
aziuJs9sJ944WKQwB/kMwFCIWndjELonIVAvzgl1w+FTyiFrpMfuVtLxjw0Toq8wSAdxYXTgPqSc
T2HcbZrDfhSfJ96c4e+czcHOdkfthIt4PPOLC4RxCMsKuHaRpUlU4rPeLEmAEjknYTx6d+2eJsFY
puHHLv6njYc2IUhDQHXhYhalfRC1QLZsIJbakyBrAbfDtye7D4FEW91J0mzSjHU7SAEjLxmX9Lm5
9owJpHa35fRJ2u4Qji9yDoT/p/CeDuCDvfjXpj5BryW1d4hY/Uv/JInPr6rpGvuB6G0TAYBGOusv
5nM/GYH2vBv6eOZDc4r9dDtb/kw0q643BKLO9f1OR4wHlkyf1iluTVdL11ihWvxOq4T8HUaOfF1L
xwRIBwavJcM34glbsrR9Pe0po1BmAbjEdFPN2lSzXC5lt3En1pd2NUcjMuoZbALrtektU5MENnH8
als5z9pcnWfNA2DXopMBvWHZpr5a+KvJmZA1PpCLvYywrath06T4hw8fAqSlxMg67OI8FydegGQZ
tBoePmj1ut1Wd/Nhy93cbvLqdvqwVO9tbbW6D++3up37an0bHdlqb2+3ut0d+h+rPQahiO2LyBL5
grxf4JfbnV+peONHRPsIedeYK87NRFDPNThaT7CyToGNcWhrE++WyrW27ooylB61SczU+1VCqA+K
TCcHM8aHjMIrg7lYqE/hN9tqP9JgbHSDFuo4SPixO0O2deenkqCYV2P02kVu215zmyqdVIctd2gi
6l0RCFaz391od6GtwA/HDt1aX3fWH6yyblXxgxA5BXmRr6HPdyb3PZDHlRpEhaxPTALlH1wQ5aJl
R18mNiIqIb2i/CzI9iGiqmOVYOJFRuoFEy2U3vUn8WiR6n1kaVcaU2DtMTWiqUFwuZu2DkOk2qCw
rYtKt+mqprbFbwvil+jcLfArhbQ3mfR6erru2tKEX6zOhnPFxmgfdro4qRCTNteSkx6qDCeXDxjF
d6itdXfhkiGr0gffgYkxlcr7963yPmMTKP32SQRWJoGh8SRTBfACDWqCdlfXDDQ88/n+vHMf9IWJ
zglR1IZ2+lPUAa5KIPSaVMhlT657yeUasnjlFDKwp2i/v1pdw1gKsS+CSV7FKI9ml33Qg3e5ehrF
WdsLQdvxx9cu3znZA8VXBp+yiIFMgQCIa/DhTRsffiAIBoERWdzJInigLoKO1gbZUK8qZG9a+cQ/
0CihaU9qsYdGE8XuWQUelTqLBTo7tpFwup1MRp1Rp8BlZFfddBqfmzpd4uPtQL8N0w2ikKpxzhO/
zRfcheCSPbIyaHqwqW7oVoJtK3W88y+JlvxVdX59EXdsi/gGVHB/NfE5jE9hRuPwxEuK/aXOqB1G
KcXOsRRFVAPqsD2JdiO2TffyMsBJYBiaVv9552Fn3N1cl+krm91WjxmY5Lzu9M6mlmmlGWXWsUXQ
nsVRzF5LPfz6Bfxuv/FPF6GXtF74URi39qmnXtqS5dgIEoXoKrhAdxt2YOc+TvAOzfKE7SLqOoIJ
cx7mgoZAqL6itnutne3WA1xOD5ra1JBOKDvVh77CfjsNQiktcIAdPj0YuYZ+CeHeRsuYH/pnfnhV
EJ1llvv7J29ePnv5jU3BzgsdvHnz6k1LSdh/8+zo2f6T5xYFHAvxF0Xti1ZMJiNDL7o8n/oJnxE6
RrqSNsWOfRmQDYPQJwxv/0SvTjRyS+X9HajbvJLTXDKzfCZ7ku5NxCqDNhTra6qBCwOGodhItzYV
E2kXqNdhNrm8sMMtS7nFh42OfTRR+sL5B5oYvbuax2lAOsgkuPDHuwnjXkxRZzSGv//cDqKxfwEY
211Dj8k7vbnTYWKfp+/jn3fvd/3ew6oF3Wvulo0k32WwIhlWiovfi4IZeX72qfUgctzuduoQ60fX
ENYpZiTgtUN/kpFZRO0Ltxax0qjTVxVmpMrKkv2gqjBfDlQaT0/j6FTfqyziMxUFxm8UXFW1on2a
6XjvYBtEQ64UhLa3UeFSNFbc3z9jdzm8KLv+J9jDJgm+H+1wjF6hI9lVbvSjX7gQ/tgAvtXcFaA7
11msFCO5QeR1r4uL7GGHLTJSa9fSZBUbR+nKtDS4s8UaZOcSqq7Ajh7stjb7uQERPDbeynXzVi4d
lnfLonazFU6rWu+UYM/WdWgYIMo6j2cKkgvAdI7eXe4ieXTkqn9QEM1AIut1W72HLffhjsFQiMRJ
HuK8pKfwkp7GFUg3vr7n4l3HO7NdXDNw9PKWf373iuMmFyjYEDp6czcz43ZWNuMWxsdtXMoi3zJN
WdtmH1ewnts4BcFg9vr0tsrNfQPg1ZoajHHEtQNKq2KTscwPa2Ypd91RZHxTfkBPHYnDMICNTEeC
GJZWjultdzk4SwOrbBqGdrIJTJ5ffC4ZC+mfosi6w3hYpadIaRt2mTHaLtVWnHQxm6EBQT8r3sVO
tslfgO0bqoLJThFve3gizlhtven3YTmdvAsybgxO25D6zk+ME0RRFdYMP9SSesSN1IhSWhQNrbiU
i8epOQj0dVQcCNg0kolpmR1eaGOGTU2qVkxS1XWrNSR2rod1b6OHCQPB+KHf9X3OC1Dhv1JtaZ2V
tOGiDvCASQv59lWxqWvcs6KcdS2UbA4lu75GHPrUJzMvxB2X+/i1ueducfWznUYv9lGMsGYjd7OD
2n08LGNq384km4PjIRZLmKneNC+7yiaq7Z1OdxsHKk/PPoZsUxwR3iu50nZUs8Sa52xLMEjQxJam
CzZ54e/jkzb6plWZKx9WbOYCDtri1pFmtkqkmV2Dn+gtXK1pmlNsfjZpwDoZ2I5dENAFuaUoobsG
4tSMCE4eFBE/P/ke+A16t/R5oLXd21noHqjYosa5maa0C8sozWQYPLlg1llBXb710HRje6kdyWQN
VTuEiqpWFebwyFM1X5tkv55KDdvGLB57YRtxMk5AHTZsR0GU+pmiNm51bjpTEmfGAiDdc7O10+p2
Wu79B0wawa4AOYZQEQh+kTSAi6GjDvWVdGaGDhhOY6dHjliAmKYqqTwsGoFv4JfVKzhmbZqOV+jF
6Nw3XT+3dprakEXni1thiSCworeFzeUxb8nRPZiMftzIx5FVhy6e+ll6BwdiudmTndiq8D/K6ZjO
atXmlrLazQpWy+5QwOT589SqRcqBbrGBKhVWOIhRKKPEU2FlZNgOV0vwrPXScfG/7dyFqaty8U7B
Oc/m08R62rOvNBwjOYgw25jStHDhLDtoVp2uur1eq7vTa+FRI+gYTRsgZSjlDhpF/8otsci1Nrqd
pmKRpssdTtftcXs04APvMQbRBH3pdUJxx6Biru3G1jPHhFCqR8TBmrPM7d8qrAlowv4NnduKcKp7
xQAX3Ns9pU/cT0s/FOjdkZxc9GLRjhWJl/J+ZH7oo6Z3eSM1xjhBXctO90DpBb+vB2Rm9dgU7pk2
C0gBgqP4Iu7k63iHOYkFUCwRy3xLWeaKU1/POPvf3Gz1Nu+30GXSzfdN9Im3Ly6TOdgcG5WFhZ1y
3AcpXXj1EmVFMR5OJoClzhwFoV45+sAWrrTjjAQDavmNzZ3O2D8FcUkpTOv8qvMrkjy0k5Zt5btb
cSJhSl7qHmVzF9Tkn6JUQodltIurUtD22dTcsytOT+492mD3dx5tsGtEeBVl7xGqi84o9NJ0UKNz
FLwHNA7ORBogs7anJtDhCd5F6hYvCkHao/kefYBezV8UoIjovjNeONPFyaONOXQAwO0ZjQjNHiDj
gYoTjAe1nKK/8sanfk0URz9dB8+8RGGeDlQPKRuYxDLkB//D7h8Q7DA+xQfB5KiyyCG3JQ736Yef
qPULaPzRBqsnOk7/vfdIRELi0DBcJAemnO3yXipjxSnWU1Q/b5YD2O3t7eftwxfidTT68K8pCxjH
0OsvEoZeBa0F5JLPBsAlB9C9F3HmjH2KQeU/2mBpj8ixLx/Iax6fuObgZbSBDLleo90bw6iFfgbp
3He5LfMtrefTqiM/iL6ib3UGauqYBc4lNVClQ3LskpU0d6987lVMbHD0GjPmzecSCpuke4/wigpP
gp8w2iTw2oSiQe2ldxacEkHnQyEjIZr1gfS8dHoS49SqAz8DsL9bAO3/5cf/7oO6NTsJ/XxkRSj8
pnNtj1+fripLb67t4a3mqlJcg6zt8SvHVWXxJ1A+TMGHn/xKqOK0trZ3yH9VlYaJg5LP4b/VMNkr
GQAT1h7+/PCTsvJgQpQZ5DjGmg5HdA6LyQvqnOgsDZmkkYSL0lHu1OgLlF+nqe19iwxMUjiSEbC0
32HAR4WQGZja3l9+/G/Fwt/N0V6glvXUkpy1rN+zF789OjJam/2QZbhc/BV6hmWPaA+5+65JWtZa
5KS+agd58ackM959H9ky0lrE9bVq77Dsx+qaXLhai3xdr9pBXvxj9RFvnH7415lvtMrupb7wZ/ge
6vJOsuJPg/Tdsh7aO7rSrvoiSEHC+/AvzvfxIhE7674XeaEDuwjGKZqDAMqdTZ14ge9hQd7YP6MM
2PxmQeZ8A/8LZrOFRwxd7r1yr2IieVFq4WNRdykxelblkB0hFbD1uw8/JcGEvyfzlx//p7XyC8SW
jrrnPt0BTz78LxgZqJIgef+woO3fQZnsw0/QGgYn5uKZa4X7El1uJWDNEVcIOKvt+6MpCIvfMdwU
dn9HeqPL4fqJg/Ip6F9elBU2D4RIobnDsBQm694zVgrAhZ4zw/gVkgAKYgYb8hPqfrW08WQxWkR4
K4KAM2HXx2A+iyR1LaLIzQg232EZrX74r3hy4GcOCFyJj7IcDQgaprAhkIDvu4mgPwpxcqyZAi/f
OE9jdVs/QruGNwGC06QQnTjk/iq6WMuHIgDdfvxPmAvWh58cuZEwRDz1kyj48K9JPl74lXz4aZGm
gb/ewKXcJd5CW2HQvF+XusBHAkxZFYqXIstLd/e7xRLbyhQUAdWnkTdPpzGL7Qzq7UkYoHC1BoaY
tLkGerClG6BIvku5HE0WwV4RCy3yoJzlm6GYk5/z7/+v82ruR+LzFbCAfXz5a8vtyP1EfVKvxV6a
nQBbALUtRZ3Nx3DcGMHj1J/hywXAjeBrMVamhNSOXD/G+1c1VVHjgzngT6ZzTY0YLOFqX7AAJh/j
dHNlr0hl/NaWgQV2vQo1/U0Q3kHJDFIaDwxyU9e72c6mI8Lc4oQyKnwraxU66vPAXyBOEEd+gv9z
tPbwfmFt7wxa9enRilQ2Z9Fn2Zb5W3r4nbHIaRyO/WRQ++Mi+3PL+TrBpx0s3WFX72or6tVvPvyE
j/t6mewEu+en9eINPQAMdWL2fCZd4RnUcLaAm3PFi14s8mFsMCxWjpRYBHbbTj7n8YBtiOJZgpKi
xewE1oqDRl5YuNFlLV+toqy+UG/SHxFB2DpzPG+lHonCN+0SeWf3ZMdexjO+/SkLp0hVL73ZypSz
moR06scYsK5aOkJaixe4+4MMF8JiKbFQrbXEuXVJYVPKQseuvfMvbQLtfgibThChtWzh32jdG7gn
gPhOuMplLes/9LCbiYMBcp05dBslXZQ8mJg3QjBiKZUzCG8e4HPzSyxdEe0iIk/jIn/58X8s/X+F
Ull7t185XnS6sK/j6LQmGAsFjcpXbXR663aPeOzOb4+OXtsmhVGpX8GReaxPDshc3LMgGtS68Ne7
GNR2Okr3eWzQVUdw84Ww743x8Y60bJ9D6+tsMXO6HYeM3rfZ6fb500UWTALsRVaFSG59fcHK2RHZ
Eeyyq2CSV7w1LXxLAcNv1HcWa3z9rrN6t+75U4xbfqOOU8Tz9ftN1e4A4UnwZ+Bxsl9KSXlTtba3
9cCZAvsGSQJEVaBSVHTTEthrrR3rjoXCLefS1bvWERRE1vyXH/87cHerNp96Z34prNreQZT4p3jy
4dsUdy4Rfw3rrlpvf07WeAGKBHAcBO2mqpTunXkRfwybbfe6Un8rM5RUXh1PaG66gs89y9AuI7V5
m6WJj/oNK76WxYlXXV1LEzrHR9LPmI55M3yqWu/+NA4uEHHKZHIlDMWKO1C+sKefSPP6Wlcb/WhM
VywM2Qw79Jq/FbAyDayzUX2tioVFBUdtv6DeYCaIPczKjjNw1ss1G73oKaOBb8hOcbZVogCZLd6a
sR5IrNqH9iJmRk5bJ17Ed6Z1vAHR6MO/ASP6wbI3yQZJlf2WtiuGnahawpV1SKoK/eg0mw5q252O
Icj6Fy5FKA3D4JReL8Mo+6ACBQi+pg+a4H18UezrIMxwHytXSrAzX5Mz6S3I/p5+6MPesPiaKKRq
unhBmxzx7GnqpB9+mnsJqGp0cIBm2bMgOV2EVeKF0r4xOycnozbmtoADt0HFOTWnhFdbcVL0Ie+z
9zcsQ5aDfY0vv1hGitqq03MwXGCybGS8GY0Oe8Y4NZVFqXSzcfH3QaoGBmU+/ISvX/tlq19AKeMA
Iv9GXURFrqp7TNG7Leafk1a4Dtqfr64tGsuHXlZ5FlUMqlD2Oaai8sg+yyZCFLcY0I7iBZ5o0euK
s3latr/QZZXaHv0pKwMrdZQEc+bqoXyUlecOgjgh9KOy7ZYGvZBUXVe2pH2uMI68piVx5f6a7VfC
sq4UMYE3Iqyn7Mmc5XyZFfTxfexRuLByLSGJHAAnvcwg7bR6/fC2jUWTgRg5AkF9NMW3JVvAouGv
u3hnLCVe+UaDPmDvBa0/dnpoqHLsvga6evx6NwqCg4d2MsSBMXK92o0Q8HUSz6r441N/vgjse/Dh
K+fBTqeLWrAUlKqHiY0Zg+t1ejvtzsN278FRt9fvdOD//5MxSqx1o7EdxVUj++dF+sMCVFXQT+5m
dEdx+dh6m/3th/D/5tiO4pttAnGSVY3tKAlKmTxU/ap0r2W5N+rTS/7UVFW/RBkbxplSAujeP/xd
NaIFFAPdKr8MZl5BghPVVh5d0QmJicLf+uHc8AO5hRDOTQv5awZlhlGQdU9DGFZKPqmLi1tpnLl+
5V1w8eCJeAwM5Wl5pG2Zqe5ffvw/up1O9SQBXAGw0gjd7VgtehzErVVPbm1GPw7hxXAjwyT25xl/
dqvKPrldNhhR+W/giAC78+aGxwTEtNY7KigdyWsg5iW2VuK/khbR9Yc8lW5va72DAztExW8+0aGd
3uoTOuTiy1ac5/FmbnqUhwvE10dbRT9PPvG5Xt7mHRmDjihmKr4qtuE8WWTTJYSIq+0QifEPbehG
G/rxUS3+uBfeibnfDmiZrZ/2urs29KO19m/Czs99uIrGfmKMN7D0R2s5Y0Uf0QdL3ke4GTq5MzTS
+cHzg29evXL293sCoS/IEkIUF8ygoRnMKjlG0lO5z5+8bDmkKyR4FSM4jdAxDjr87PUGOrvRW9R+
5oTscgxyBOkCQhKHDtd1nvsObEcffkpi5E0peqwCgDRDr1rYCIB3ZcRt8I4b7GVIfu4aZwwcU5/o
mEGIIYCATDCeMjkP7xqIa0e3OVN4DSMAzduh5ZpViQo437Dlu06vnOlzfCFQIcpYpYYelxo2O6rY
oNS+MwEoEeb8JSPrgbi601k6shUkop5NIuLVjz6J/wRbqJt7z+RC4X4USmmmkexPPfREV1aq2POd
1HPmSTyHtZz6Kd6tcYjk8BY//OZZZP7Ei1UeyUGu1m9lk/HGY841qverJ98DdoAlkEu37FSZn6u8
UKE7PhuBmnQsyYi2NHh+/Jj78q+1B+PWWTqsZbsn7+UKG2gBzUDUuIGmIES9A764iARrc0Yf/he6
H78O7s71ne2QuEoCjZyYb7Nwl2RhsoKUPrhvM1cSQ1/ZVDm6XPsVVIFlhy7JApHmd4k7tSLuVtuF
lQlL/AmgbroaKY6yBY6o6GZtJULel+dBmhUIUY1zVUqN/CIDd0CVIgmdkUOCayPQtXd+drvwhlKU
mGs+m+x+oubjjhNOcdSQRDHMkT/GAWWoPxBRMBcOxkk858NPSKz0Vmoyw0HT5R4fmQu+GrxI+W2Y
25AKjvjFD1m2NpE8hYq3pxBxKVqEu6sVb9NB1msWmLKmFefRKldgX+JShsnGNPv3HTSDEnFZG4IX
30EzfHlamXIBqXgBCmrjQ2nO2YKuV6HoF4IgNQV5HxcVeg+BlKcoG65zACQMImlEsirQ9NjKyPzJ
xKeLrdSvAlsD6nTmPlBDxCRWSbbcBOHsEmy5FOZ4GOBFowBkX+zl9x/+BSp9+CkF6JAAEh+COUni
d7AFwkBSXDp4SyzxqSaUBeYPA0r80ktjt+D0r8XapeV5kiyyVLlLwa+vkYqEx0wLx7+ARYg7QxZE
6Oa7uHAmi2yRpCRExLMZ3Y1PnYPD15s916ZK4QxWb36l2hRnNDq/VYKzrspn75a/KneubnPNTDPz
0gQ8J6qLIh+xvMgCZDtAHEALwFI9GN7Cp2uRkECmGyQrfOuFaUweilW0hyONTvEcSLme5loDF5CA
w/ujYdl+r2x9XLEb6TfCE15jFzukwNA/4/JG7KCuCasjDhKiVm0zARyQ9oki7Jjfy8qXkkmi2max
3ekAaFgFyABAwHdL9S7lsY4qzYtPtv2qyinPLZyye9gXvBlYdmIMo+R35O35eMtcXFW3lygGQLCX
U4Mf2EsUAx/Yy1E0jdoeD2BSOL0uqBN8i0YyWH+LVmNZpEsul/LqTGpR7AhOhnoKc3bYdlLXzqOg
ARZe11ejkohHWm6ql9yEK4moDjfjSjIUhAwxw3kS7KB5IBMyuwidJEVXEDRA0KHK1EunfDPkymTK
Nrc0OKVt162MnbKKHUMNqcJvnJS7698itsrt7n69RJOUt9DxZjs86wFfT2AY7Gotv+1QaWxfdUya
tV3dT1nSeqaJ5XfNvejUF12rXqv7VJYEq5kWH6eoOnN4t4pDo/5EzwjloJpf5MegTvkJrhZMil1p
d5IYVY9xgBswj1RD5Qa1LFn4auya0B+fXGqQj5gXlCaq5fGnrBn6ujS7ygG+UG7WF+QIs87h4oR7
Yx0ugrMAkU4WVuU2fXlkBYJgCQqFb7NUBIXaZ/oeB67Z+Asj5iG19HWnZhntyGAYFExCRqGisJNm
z5HeIl+qgVTGQtertPaE85vK5hgvuYvm9oOT3NfY3hqPI2NrzPDKUKkBY2vKuVQDblpCaCnZfMtR
UgY12CQXZmgwEaswX5uMrFj3nvozLxrjWQE3m8HGkPe9YLqko7lZwEyTwFK5WOqwXiSwNuPMrWZZ
S4bAV8Fag3imrZzSzj/J77PQmvOck0UQjp0zFnIDFZN0wUxnFPkEmevkdqNBm6GXZGuN5k1Rz6wY
1HeRT5ovWZEX8wULjMH4CczIBANjoIzAVGz/dsM58wFRl2uNRgvf4kwCQGwVgb3xZfA5tHqPFLbF
5+yMBZ0SwUfsWmTFejMiAWkhOfPwK3+m03dc8vyMlBqPRly3U3m1W9HYkYiwabYnQ29q0fyM2geh
N0/9MZ4oz4Ad0OEaOgT0nY6TqtH+CmxPhg80280DC1ZsFqDIwE4GUqKnsLzyQWKQHGPLZgai5wam
yIgRRKg1M5N5yqMnge74b/DfNBAGHmlr8V2HmZkmfvTh39BwlFHsT49OHn28z8RGBBNTPHJc7URB
RRxOcViMjQjMI4oWoSWKXBHzSLD6mcRzO+EshRXGqW8X3DjVfO2DrG8aQu/ZlwA9fZVvNMpLWEJk
Cs5Qgo3DIJNxjUDZIce9vXuoP2XOLwcAam8cjxaEYdjtDkJC9leXz8aNYNzc5QXJN2NwxcTCPqAu
bAkTRv/tcYtruywDVVr2i6uu2ge38bM0ZEnsF8MT+32ySC/7Ew+krhaql89jj2KOshSsoqcYhwda
noL+/hWenvfrI5yGcb1FnNwfP8n6nZYku7wmZ/WHvh/xFIQ+foUPabNPkg769fr1tcCSNw8GjUUS
tkD7HlxdNwd7Ez8bTSnpagSLADALcm7ar6fezG/HSXAaRPUWiqTABftX9X3mfN4+Au2j3q8rNzY3
8Lmceqv+h7YUR9v7h2++hlLdest13Qa06XJI799D49eYConXMImTRcR0XD8dNc6aV4mfLZLIOcwA
daeNs8eP6/Wmm/jkNtTYePvFo7167XjjtDUa7DWu6l9AI194s/kutP8If4cZ/tzDn6f4s1avwc/P
Nx9icg2Tf1jEkHH9dnTcbF7nzU9m2ZNTv5Glzatg0vgM/vKe1L/3QH9I67uc3AYvgKBcFomdfk7C
OE4aT2Ey3Sg+bzQ3up1Opw0AmrsAKX200xGg0i/rDgCi1M2djkxXwKQbUByKgUrICz7Y2SopSSCg
7LS+a8tmFSH/+7o+zqc8aE4Dxlo2HJioTukAGCZmA7PfWHymFJ+JgbAKU7XCDCu0ktlg9qudDlac
PuptiYpTGtWXjWT2uO7Uv0wEICDpJgc2VoFNN6BuK5kOpr/qbQlkjGnoAGTKgDCgCEJBBzGnxrsg
GrfYhQv+juoAil2xlk7ii4HkQ7BUYKI5K2rUgXPVKdC5S8wOY5UM6uwpyvqXCJXyKBr0t0cvng/q
Qlipf4n0Tk3CFEkxBbrLO/C4zqLrsoI8kRWlZELFLxussRTWCJ6CRON9fMG2AY02d1Nf+DE0GrDe
sSOJP4vP/EaztbUNpKGgAcp+Baytwdg7sbkWKbbNK5bkitfBB5iH84V/81xgfQDDZYFceSJGmOds
Y7eYNKCy79/XQdLHQM3MHla/9jH+O8EvQpbtqXBsBXfH+ISn79jyrtVxT+Pz3wX+eQM9k5pXcpp/
wLuXhz6zoD8Jw0b9rWF2OwaUT+LkwAMmejHY4wSAlnSXORo16ixoar11IdvH6q/JaDcYUIvN3Yom
8RlKJ2/3xi3mjU2hcJxcCn5KkS0btLHVgT1+Xv+SyuHs4g+oV8ddrt6koxj41dDysA2Wh8eCeh7f
+Vj2a20bbGiER9v2Po6kQdZiYr/MbgxgYrL51CUvxoj7xBdlCRgIrK5x/f17mUS7I+weeloM60Mr
NvZPE9iTxjl0tGzo0AXV52Ukr62feON6YSTkjytGwks2rtgw+mI4rXgy4QnsR70lGurXQRxNubdZ
vcVH169/+BdQR6Ig4cIBCgP1XHnDVBofbMxJAtIr1hXjo4L4ExKvm2+pb8ccD7D8/vLjf9OGwWSn
fS8ZN9IW2hWhMwOSKwRDRP1p8DZ15/xqeCt1pT8b/AbheHrsstdnGl/Fceh7UdMFKT9q1NEVS7Jw
JiIPoMYZaEQ4/C++SIligflVh8sTr7iysMaMR7KqwCJre68WZ0mQS6vALC0nPh9+ZCgVHFVOrG4z
F+c0pgIrusANbKaKA/xfpe3UJTkVeydcGtTg+sD3baWRBInkH7M//bJCSIuP6b+lRYi4H7M//TpF
869Dd5pSFxNYZJwWd5qyIQsVVuxNmQd0RGfIHoV6AErDtwWSeg6lFFZaDDFPVsZS9Il+KstN5Crb
45eNzzjtPmZkhvul3huV6hPYOv1EnM82BKWD/jQg0PLtZNxy1WNT4Mn57g7FQZKaN9LBnr6M2PIR
i4Bt3IXIngVQKUjYPohlW007VDRCq0CX7l7qqlF3kxOQDtw4GkF77wYoK8ht8URuJLwupmpys/Bw
/jabhY1zyfPqpi6MZehBhpLwxtx+aj94oMrEsMT0c3H9HKg1zYb8IKdppVpm7hlLJ3EevjTzq446
lnWXxWW6WW9ZgKWqzrJaUJ4VHaISmIxTUIaQW6NMv+FgBKKqBbbKKChG080GQdGWVhoDlbQOAeMm
LV+V/Jj6W98LsymSGNcmgOAGBvXhujIi7mirCutoa6+8FJf98fhjkENVXRJR8Me/quhvYV3nnDnx
wpouUGIVK3I4AURsnSj/DvhM0PHd40ZD/Ryi7gFMWXqBEMZx8/1Sn0ZW2stktpreBKa5C0yiwRoN
xk48cd7W1RBFIDbqoXfrx2KCQMr9JRlq/FCT1/E3phXFV2Q79RYXGRr0QFXzukAP6JHAiSHSiGFt
nvO0lCesuhgihq10MUInlKrloIUHvs2aFRcqV+1p5HqsxnCEUT7yBVjJKZWAxrfpLHkXr9pTleAj
dUu391MJ2aWwD1ze6lWc6vX/srKkwQPMm0ErMoDoLhhAZGMAkcYAdJIsLOxo+cKWl5LUVS2jRX/M
lQ35CYDBuP+KERA9HaBjZ0yBQ4Ng/YsvzlwWX2Vv0O09PpNCUrcHgzJ0GcYv+JkdU3YXYgxoHh8s
3EBErX//nkzIoJMF49CvX7dA5cBJtwS/rzdbbGowvxjKHrJH7OwZ4PNfwIrZywf1FtPRBwiXzSmO
jo5TUTvVk5NFFOGod6EzFqyiab7eWrDyn0F5qUgBnj5jDTWprrTesMT3762V3r//7K3sJ+jHZ/Vj
l+J7jEEm5iMhLd/a+Sa3wWskUX9mRO73MjpWweNGcaSLR7lo+uEK2HWhAYGG1VqgtwGcs8DDIx61
DRktiu6VMe9eukIkToASt7wPxOL9cek4871EO4cSsfJBISF4qBelU38MK/OxWJj+uYPW40KBX6Mh
uQmzTZHBfW4Sb5Llr6yb7N3AAiHRql+v54DJDz/hVTjRdWmYZN1W09QuWZpY5B3Jie1xXXNlyY/G
W+jdile6IEsuTxd01sq3IIrrni1ZXPFMhWMrdbDYVbPp/AXKmLxeeVwElzt7MSTP4E+IQBYZQ2Q6
vg4CifRsR55Kb3tUs4VdK6+y7y/1XYKvMARvPObcoMnztBkmm5YyCTMvWnghkIN9+2JmsNV3qxcA
zodecSzpbbNnX2a8CGJLz/9d4ZDd6QN1AYqYTjfkp/BsGzvTzvhVj03FbOarq1gZNt3rZHZBJZXY
/V2hQvNBsGNEEAFZIM9gGbwREfiRJ3578OQpHjjDolu4+AzgaApEggVhI0cm2VfLk5uCotnyF3UY
TRFLLSC80PzTg9+xBV2Ccv4aD8g0yh6db5zjISsAbOnw6MlXzw9omizQ7HOS84M7o0aVq+CbmHEU
0AqDho3BA2ewkSx5ceIFEua0g88SqXCKNLwMhUtxB8X+8r/974Vy+MAkWjdkIYDFaMJKIHR0Yh8S
TQgHl3etelT5dCpr0zaz2BO6PKNtbOI6jbrD6eVKtjYiEE7KQ+JmzasiUzOKFFgiP+riXPH62kp9
i/kwi4fIokvJj504rE5+H34kyltx7X8lKYxTLKzv/MVP9KYS6Z9wJeN8Eq9UZlNuz7kFQS1EM7eM
A1TC9SsAC9ZhnyG0et+UReOl1xjkM1oC1pUj7sdqT1qJsC6WWWmUTouKnjohmaQyWL3PZCewIbTn
4rsT3wTZt4sTYbjh7krSr4l72aG9F0QfL72MRo4UgPDQjYs/Qt9JBt65F5AjSKO+Af/dYLIJW3CJ
yzWawWCr021eicc3cJEBrIYqcH6WuPE7fh6myVIN1kLiokNIA63ERreUp8lkv7iaVXi1rE4H2OxQ
OovI1t2qmy+0MUu6TQUzVYQMcX0qvfsYbmmHxEepq1G0QZ2rt65gsqfxGFboq8Ojegvf9u3Xr67r
14RChpYr5lBARzFGf1Va0wfHjgcEiqtQuhv6GalQs3mWDjpcap3HeE7hZyImQ4Pwjob8K1H2y0F3
l8FSaYP8OxTh+HGuFSrCkoCBGjdMG3DdRLaETdsGc33dIhcDGPpo2vBhpy2ON5sm8bnjq3YA1g3m
3cwMH4JOFgO1o+hGhJ1vWETpptzexVkErkCrQGXbnPVNVx4K8rVLYDLvdIgH3e/fN3BnbZhbKzRQ
b2qnJKzX/IyDDWxBJ90rDWAJv5Z9ZH0xuC4/4jW8PRgFkEd4g/R3YKZAdzjhLd6AksI9zpQU5p+b
J8izYW8+uCKAAoyozKtcLz+mUhyB1VMq4Kl7V5p1Sezxwu2hPo7xLF0owUKpOxtAr95CTXGWtZCD
P6bT/i++OEOSl2PRGkHd6qx5reKP/PRU/VGOXiNSyiOfKHxBnLtFxKeAjxTtMzNXuO0JZpqrkVgT
hm7X8Dg44S4I36qTIDurp0TpJijTRIssoURl5jqxNpaVR8g79f79ZwsxrBUNblXasY4ZfrXD4PK8
FgiV383nfrIPU92AbbawH7NFX+AGwqGqeKfDaMe6lo2ajIMZFQH9lAzqZ5HNGVhkzr2wrAy46GxQ
3N3Ey5sjcmDWJJXHJvLEnSATynPphc4DNyiimYjzQWKZcu3INYFzg0mJEmcvu4rQpl4qKgwImVjp
YjHwJ5zhVyzPXPgLqCqxK7J3TJCteeYjqNLkqFgbPQqFpd2fwMvdkM78z0EMlAqaA1BDjE3kiKhG
Bdwzj3JtYLoSZJYXNLZyBVzapYjj0suyualswT491Z0qjrp8Om1DVkszToW8dFCoyC8z1PlKVVku
McdIJfrCHQi+AqhcGcGnc8rRLkdoNACMK1FurSjmr/qusaeLrZD/kTuk3OM+0cJVrxiZcKzMrLBM
1uFf/FoS6s10zjAGMQQjbYAWg2TyZ/Yms3mrpr7Sot+XeEdpOE68gIc7DJhyMZsvfDdnjQ5FEki9
wDdvi6iXy3tyOeP96aWXWBSmU1z+q6zO5XTK7B2VdFp6gafOloYUa64+DY19+FHc3vKTlWhMOzGC
2aDHu/Kjo3ihR2ABoQ3fvvzw06qkSAcV/PTEiTBAJotYOF4EGYuxits0PwlbkfyIvJUraux+G0H3
iKzZpp34H/5PtIbzYDPQaOjRvd8ULwDDLmTSGB2BCUJL6IQuScic3EbnUyDLM3lRDfayiN9wR1qF
Fr2MYrlN4iDNL1Rxavrw0wo0avD2smOt/IjRYHMFxmb79amY3YE83lyJDMWNWNO4pN6QXZn7GSLJ
GYb388mOREcE1NLqpCbDKiLl+khtITA3RtfoJgjkBKIOLBGogIxQUnkEVE9sL/FvxqFKD3+/+EJT
aYqkoO94+sb3qSjAOP9ZgQhst1bXmHRccYj3xD+jmE2RE2LUVdf5nRcGY27vWiAfmIdxwPaf/Mz0
RtIu7HazIGJxtUYicFRKPAa0tSCkSCI+MbrUi/BD3muVbLogHt8trZQSRwW7+FQkom4+6+9WYu5u
yheEhmK7k746Pdh8J3AqUbJxZjFZd5zDgG42S7EJBVkv8T7831mL74Dypi1FAgG9x5SURFxhReq9
I0pZ5idhJx9e6zbkQ6cVt5B1/iu5ZKxNNyiMxIubbSgi5IJH8Xy8kGKSwtYAs25ZuVaiUZ1F2F0B
fKQd777TSxanqeoPNEcZeozXSEXLFPOMiTMI/O7kityrR/MJ0M4FV9pn6M+qNMBk7JsTwRFx4KI8
aiWDF/q5lTjJvYM9ZqWZLznyZIyYXD2Wno2D1OoZnh9c+vVTsR0R++pLbxIJ3noOuTrEG9LZ37SU
+prFDlx9A1Ir2EIIrSxVcjFUWhj96Cy+RDw7T3KvQBBbZ+h+zLSLcSHyy3obgGLijgHR3xVsQSUH
THSityjxk9QN2zaTuDTRc4MTJMhL/YPOzS32u8KGPLCZkCvODwp0WnSBKxzX4tkeK8K3kgY/CRx0
6OyKf+0NHnZ0HzuCmPccz253i/kMQzBm2Anqq57jKlsamnTQOL3LSYVWMCioUR5yWMRUVdV5t24Z
vVy57IwUHVZeJzFKqI0Er13Jm9RJq4dOmU06NrYcqBaHaZlpW/siuoB+HCtPS/jJLB3Y2txRq1Br
a44fU9NO1CrdI1qC/Xs5CtEOtSABPhJ+UpyvutpGm2piVmp6od6ww+xcvUS0aZUiryh6JFbRQ/IY
bSTFE3JDSPjii/Sz3ErBv3Sv5XXHy5tXDtCrKatkkakshYqstM4sgaGk5vGXH/9nmRXavrS461U5
O/myW+Q9mtv97Xk0i0tg4VEVB3Kaf4rtEKGUp8lTXkuJfBvII4asxjWqJ7esjLF/FH1qDmATDpgv
jdUxeiWCISDSH5Xv8hYP/xWcbfjMV7rboBfMeHB1TfDGA91JJl8yubfS1V1sP2OXXXwueGyVhOuq
VzCtKN/A6i0F8AEpVYIPWefkynXdRUsyt744RmfcVQQw6a/d2+truwvS2NwtbLtwnYcL2S2u8uZf
h4fl5zXKAQ1Fqc3NF8z6IA3/ZGlYKinYRkiyR3h5ZXOEKtwyp+5S8B12tZx53tHVcugZV2HM4YAi
k7rClZqV/G6Oi9ssuKBU5k2ZR/pxWfKQHTeltKwxVDTdNDBApC7muCLc2fixiFuRx6swqys6Cp7f
BiP0sLDAeQcwcDXI9q2OErwixnv4Eip8yb8xvoT02WJJ6IUFSs3I59z6HOry66nKXWDrIC23ay1V
rAM7z4UAjhk2NC2DY4pHZUCHMAW8VUWquu895V4r5depvxdhljCiBt7kEzchl40+UkavlrcOPSob
erR06PRMhXXcpVdUHZ4Oi0WMbj7AwCO0pHMPIhmmpcU6NeRvA/U7LZ+97ZWnXGNfOIRlqJkrqDGq
WLEzL8POvBQ7So4MSCOjdHDMyYeQbMibu/qYHz/usNv11B9j+DxTmHBoHWNoRH/2AhRE8rvQFyLL
BPkZc4dSvBrOTgDMi+ArgHMC/FkB9DRI35WBgXl6N5wkvj88PeF91POyGBgqy/xGAW4PBLBruQ8u
pDbyKZan2vK6brlGfGK5xWvhYCwMC+dhJyvZW0QcLws0eolDMlf2xclDiWWiR297Hp+iMmqLVIer
RjiDyjsXWVpyj7CwMVGEJ3wDIcArF9wXBhGZB7pn3i+f8UKP+VVcKKxhovJlDv7IAn+CVFqZXXF/
W3gqKBB5cxQF5WKwV2iArppr+Kc3GgBLynV9gbcLN0uVSDGFajLiD6t5ISKfVFQJfdCDHVGevpRI
NXlKWX0usuUVCuHeOHKUYC8jNx0lIIkcxfOB+P2tH5xOM+ttABa960pqs0r0yvfvPzPmWOhOhaJM
/OKmCoYWTh88iA30UMSVQhl+l2WmJRKa+hBCtW6AQB6LFgFLET6Z9t2bZ/sg1cURhuLLZ+mLMJgF
2WC707np3Yarym5zER0laVjGiyS/bigiE+r6yK6yusYup+X3798eNyvRk5cVywxDMhLzpgUEeyLK
BF7hDQt8saKeS6SFOWSuvxYqOQXSMq5lUKK8kCES7HipW5RLKYQzBbNqijFs2AaBt6t+/3z46qXL
ogAEk8vGlXgloC96JZ4hEDR43dQuZlR3/hkFQJ0EHj7VFERneHrOdh7h1WhtA0fNBnICKm7Brpbr
IGiiPAkDtEhX6grFSUGrY/OqDFuQW60pm8SucH16O41xmsZpEi/mrXQxmQQXeeA6SpXWM0a0eEN9
3JgN9mYuKw7ritdTYBN2jgDDjTMOlSJqcsAY0QHDDr5/j78WsDwm+IIWk/v6IvZr80tWsywiEEUd
pC7K3Yod9AyKIxOC98ZI+HS3mKxdVZaVgKIkc1eVpAJ8cxTBqK4UcT9/Ns04pDHfO+PvqGlvQZSV
4ZHn5DM+lYV5YHq2B6uP9RmIUd7r0wK/LAnQxillSnLY48pobdai5lZXIkM8Vx+bzH3fcD9IfHHl
FFmzeP/Lv0C/F7pFIB6HYufI1ufVDE4OOytDisufHsNrR63xYE43SegD1hd8ilVGSahgD8Yo5o0D
mTgdDZ5Ag5dukNLfBqOtxwLyY1L90uZjli6SWSrn/6DNjE0wRHgKlLF3CUAoVcLANAli92+QKhmN
ABJddqvqLf4MvaxFf+NIRpPEsKefKQxDyEMtp958/x5UKcDWCIUP9kNc0/TFXS9BIFoMJznH6tVk
M7DaX5H8CWFMxzReSlFyyt4SwXj+H35KPJRT9CdFeNdyRj120Rrvs7LDUQsw9v/s15tqeGKtDTZ3
aOfGrdMpgpv4fpgOw+BdAdrSgZY+jSIWVWodDK45F/ZtiiRPS49S8P0fcQ2uejTTxSwYkwNbcTg8
73I4H2UwnF/dejB4rn4WpKWjmY5yw894RCaeJd2fJ/wt52LvKQsndjr3oPfT156l/yUR+F7yB0b1
zZbdebTtimjp2WDZfE9kH7QlGq+V3j3nUQKsrb0ZKj3/B9kIZdy5W+6EDCnaRsiNc6mxJc2FNQ82
ovw3vsUADAE3T/xDADAqWDQQJWQor53cXPg3QSd8t4Bey5DHq2w2rJocHTeVaEbN0j1JYPtvdEvC
uZFIYs+xon0Lp5OP8zH7QIuNN9jjHCNNRgPvMUfcY77ZKwnB2IJNa1hmrQM8/qDGOz2XZhngHeJV
CPhIfJ17lgQshT5q88cnxFPmIkubhaCluWWmX2b/OhQrkSmXDr4qgR7SqSAI5XFisQplO8CUTa78
On+SWWfM04E2oUxoZfbfwdTlv1CXI9bMv6UpT7E3f8zVJ58MXZ1R5w/UM958ukjsbzIZzAs223Qg
hsltiBxV38cngwuYuhPGjzL4YAuDAgzciPIugIw1ClJX2oW2uKopEXqFcq/PlkmdvXUNiTp/wVLC
3wAlE+Xw5Fd5qdC79BOSBKB8s7R7wjX2/XsEy39eFEJxFmh+92+QaHj84WnF8ch0yfEIP2pUEDS1
42JFDomEqCxocz3z97kbYzX8+Ft8QGcsDjUNW0yLZWJj9hw+KUbmMc1X/sJ2IfI45+EinvmMbO50
+pSaj3GLJcBi5xi7Ei+TxXOUgnm4eJc+378X9qMSw7iozGbzt/GhI+r/EKvnniannll2Tb6NyU7C
xJjNoK1WdNEwNc6E1NOipzJ6DCbAwHlnWFFN8/3KAxCHw8qfjc+9Fe1iGd4X1J+5dstIiPaCsXAs
wEUxGJuRDUle/yHLloWwBerB46rH5adfa4SztQGj4y55V1Ccf03jJOWHkzxMvnhD3jTZvhRn/2pn
pUNAru+x6Elkqc9jTI3dkTfHJCKS3aJdUS459ZiR5+B6E8nqLizXm8zMl7T1VIa9m5KfyigviOln
MEqGegbDrfT8vWyEJm31+IJOFjWLJnnt0evlZnn2yMsNz1E0/6enzCSXanfaU/Qn0t2T8DphqCgu
SBZ1wzWJEGeGm9KPPFSUMd83C0rK7O7Mml+KlJQTpA0t4qhgSQgDbz6vClrATfsVJQqn20tvQNkm
hV781makfEJwmBlXE7WAD8XxGn01B1tEh2W8Vpd17jxlhsVi39xl20WfrLdIk3xBN5ot/MIVzH/y
Vcu/8nc/Wqoz97HwJjhHmXM8kASP753LN+nqnwPG0BlUvJnxNo+dXZcnBHVmFcHrHvxlpBZ7P6kl
nxOBn/TaEqawB93V8MusD83H7G9facPOWgpvmVioWD48smuGddMfPRmY+JY5pEWYj6dY+yOnorQ7
8iCCZHtLp4SLl3G8yvrKaw/OFQP3QcQfbxIBBQfnQuIjmoPZzBZjeWhNDyqwJHx2kJEliABmGZGW
F2J0gRuSVo4l81BhvKyHHuFKe9HpLnFwjO0ibhkoBXjGMGM5tPCZvfpFEC0orDAvS8/hgd4XjRvn
8sZTwOO00et86DVIpwuVVbkLmlmTjhQqKzLHNK0em7F35I3zzr8UIsc7q7PNuQtUMIRiQ6HdKSIH
OURRzRUFDju0fby8qCiPAJmSvJOUru03d8/YvWlf0CvfIWwkzfhJKT2TLXEJMUd2Ysaqg0hYwYpk
HKlkjEVec7uUnJlIMVVRCegRudAxVLxU6jQi8oWWRrffYlg2BRCFaRP0Sw6CZKFJlSLMZpOqhfbR
k0+DM2IpWiEY7Gmsl+JJWoO+l4ymzyK1RUoakl1flnsao6Vf7diYpaiFDi6IoxbL+ixjaKnzNWws
SskJfKrZR7GSmcVq1nN1vUe03nVUJtlXlxomk2x4gqOXWsyTTBZ/CfoHu90gK0Q8SYX6wrsQr4Qo
JWfexVBYI0VJEcexYmFjHBidFdA7GHaGFRUYFo+ArtDbCyA2oPQ84zecMzTy1UdLSyy9/EKa8IPE
jQZPtkLyT28F8vxfLvWBeGti7Hr0NssQPYYUXiCjJv4XVVvjLbSZPYA/NicSQUryLwa1X14F1/IZ
uhFAaSvNQq7Kb7rAYDp1o3hAxVDRHLssaYiWz4ZScewGY3L/vNZP/PT+aaaT6ebes9xABp38snv9
aANSi/alg+cH37x65exj8A4QNJx9LzkB9PZQUyIl7PmTl2WGDaMH+TPXBXO0jgmVj19XvAiu19qP
x6qxD9k1pjB2Xb8Wmj3dPcjfm8bXMQBgEM0xto2135x/1uiNkUGNGOtJfFGDXo8Fc/1swBSHx3XO
d9Ej93qP3ovxH21Qo3vlDxUyyCzboCQm2nJS2nvjZyBim49rF1E/iZNZ+zQJxjpNTAI/xCTWn2dP
lRhUGpan0HZtL/SzDJTFljOaBpMJ/Wo7Q2ki4YOyog4aZn49OfmSxR4k0JpDwvA0DmGBAzpHvTYy
UUtH23RNxclhsoRa+ai14T1NAPeJ7GdK0UMLc0yFoE48z52RBjUoC1Q4hM7lS2C/92iDlUICJGhl
fV61i0/GdCbuPHvtbDhICij/VWOWEYyBW0y0Yrf7sOd2dx64Xbfb6yxHMcJZbwSvYRMiRlDda7yP
Icg8WsxOAOX4SjN0EP56wCl3trc3twvjwmqPH3cfPNg0uZut91h6zd5zHz3APvJ8Z4yno6MR3gO2
rQcvwNgjDm5N3CcZ+Bnsd36y0qJgu0sbWxK4EJ6JNXLHxGco8S1isgm38zwDK8ouZZ10nS/+5cf/
Yf1/4FC4AQcpGwqLO5DUV8AzH8damH6jXAOFiXdt+BXx7VZCprwN1gZwlaS12ekUUChrD6HocOyH
3uXjx71ViCxv9+bj9y7udPzeRfXSqh4/iHp8/Jud9RAAVa1IsL7hxnb+4g7IBu0ll5W7ILmP8D3w
CH6zsFASpfl+qGI1oNOcNrO5OSoonpbfu1A6/l+uy05Pfd1KIs5JmR4mj0+UQ9MWvgevXsoRNhT9
pXf9WPWxevxoFWNXPT8oPQZ1vssCUBj8Pzv//n85T77HGJOJY5T/9/9Pundgb8sCcOtiSuVLsayI
MKe9JFJVXo3lkN5QqWazuVKzOJmVjWKBZU0iQZU3SKuvxfZ7I8S4H6L18uAMgzsHQJQwobx8vYWN
CxVFdIC/7avFV7+MRjz7a5DZ2GtO7LaORle6tY0nClqjk7+q1+F1ibbePCbiGnnJeLBHl4Q1OuNH
EZTfbNl1oj5mKi/+omqyn+s2gwHoMy2psdhKPyN58FrDBqxmMVvPxnKhBeN0gHeUDv2s0Shfbezp
YxgRypr8/YNo0N09nwah3wAgaIxt1FHgrH8ZNZvRl1/KY3ueqD5WPM4tv1dao/qCf//+iusAfZre
Ft75laat/nbL0HL7D4SDRf/t8fWuff7t0+zOF+m0cQXoNPDUYlJsv56LrfUWynKghIhbjX060kER
qY/yVMuyA/Z7Lcu+0N/slNEAG7CSiUqPedoluOaufTVo3FZlEIFlFcj5lsthHfSlc/IaC1rdm/ex
fKGICwtXgty1dagswkBeCXEz4LZV01cJB0uYkMRkV1bU9drcVsiog3PJSghYUDTdtJLSKlA0Ec4K
TtLgmuC8/5+9d9tu48gSRPuZX5HOaptAGQRB6mIZMqRWy7SsKVlS6+LqbhYHTgJJMi0QCSMBSTTN
tc7rPJ8fOC9nrakvmPepP5kvmdiXuEckEiSlquqSV5WIzIzLjh07duzYsS/vdXMmedbWN8RzB62/
/QaqswufDB7KVMYIGW8S5byDUpHsQoZZkOwMhapBABRZvU31Q0Wshtt3san77mUa+ySRJpmSuOK/
doYBAkpyQDfJA6Zuea5HyTTug1S3R4INfuCWTsHXvhtpr2sInm57tiOZ40hkLl4FNrLgYp6DPojU
NJyaxhsf7hnlG/PefDyIL3nU1G//9/0HW/+Zbf3a2/p6uHXw5T9vd0HoaNEuJBoL04rFD6wnHnZn
8/G3CZ/Q+klQF1MukyHfF5AOoEl3yDacZ9WloZAQjUuNBIPBXdFa7BaoET4Wq5LO6WKV0I9vduSv
e3iqbwIUMhTnWQGFOgZwHMCg0xCGYweCxmLjcZgCXAlBDLwniAMf7omzYxPwbU4W/CAH82M2yTFw
84ISMY5hNH/5/xLRU1I1Go1kiu5o5HtvNPLDPXESjNUJ42u9oQuuG/vgDv///I//34oMBSqBDh2M
bzMiPDV9A4nziy9g1YnfQXkTTTA0K/jii8906+LBUqw0Gbq5Yfiv5YgfOooltZaY85Zv4iwM7aSR
GzHH+g74ojpQPheipryW0eYC8JaycAsk+pWc6xhVjV/Imj4nxNRhvBH/cxgGtemysOsXD18GRcge
M4b99hv8+WaX/soVyXtIY1QEF97uyoXH4xBA8C+Ag3+K5RSCpBF+4+DctqhfENwlTncd88REU8nC
Hl61QjI4aFjtq3QQlJaklHT8UhIkIJFziZsdioMWYDe6P2vy8O6vv/iC2wNUk22WPBQO1pOyMRm5
aE8eBK9hdx7/5c8/iylbojblL38GIhKNgwwmGieP8tqhWZMygFCZapBg5yfWftuywJLsjhyQGI3o
/nA6m/zlfy6ADdGV0xxCqp2WxbRy9Dqc+jXh9gXbK9+s38nDcj4vjjkw4ugkO51VKuBzjLUxGv61
HJ+19GFJHlhq8OScqBtyIPfY3ZQT6dP5pXQqIWExYDRoqqX0lTQsw3CXrZ+c/vaj180HP7FvuWjt
t9/iiw53FdvE5Hq49iqeef5hOKblxwHWriH2ENQedtgqs5afGGpjDufoZK43IjjkC50VY6fX28WY
Jb55LegdV1vVMgDb6CLZKNwFUUi/RqfnLg7+i2EwIpFJ7PiIztiNAIIy6rzFU2CkipXIIKyhYIZ0
hU9odOcUHHDGpgPO2HTAkTp5aG+wD9YS8yKb3N98+RRcYvmxj1b5ITeWdifqQ4NfpJUcesd8hhEp
7m/ig2jeK9Df3FSO6GxdIpX2lNI3REAEuxsW5OFuQgIlGdxSofUig1SZ1qqRUs0VMx0+wLbiRj0z
rsvM1reFInxyUhrOzACrYaQC+IBVsPJHjawMu4Xma4RN6JqsEms7akT3DYa+ah2E91YI8MnJNsIx
Pi0L6pXotzsxGnZIS3Z/WlQqdbgLYpUt3+bHgmdggIyF4UjMU4pST8Sk2rac5qcXQtaB2FqeOTV7
JrDVdvtg3eg3Rn9N6SRmzCwV/Q4p1Mgo9p2AaXJZI6Q4lSwx5+6qzdep7NrSXVa/DXEd0PlvwSHj
7Ihx6oiwzCaDRZd+DEfsY9XhgPMLDpY8HElJkD/IUD7qUcfzoaa+pNgPffUEzndUmj8ZsNqeiggu
/DAA3jbD3LU8Nm24hqGTHxSgsIL4WbmOGX2KhUnouWxIPZhGjlq0f9BJzsGGur+5uzUujguxv5+i
daV+cdGOXUfLhTR2rqf4ve/NZX9f5dNl+oePZWzLdfy4zF12rHzKOTbpOOhquY1fwo6WHPpQDsq6
WOchkX8iq0NlbeWsbN+5X+7i3PEZdq7xu2HHYcdVuGM7EsOCAxsCM6IKlTstYdLhE/2i4idC3FYW
q0iw8GYqtgsdclNuZvjp+8WpWKrw6/7mN8XpsWtIgp/SJJssBukr2VZiOSin6I6f2uKoLLodjLEn
a97btG0UrF5tb0fVYqI9jCTCmaHnmeDEAnk8Ukggdna/S6/vb7rWq0D6OlCiWYeraJd5IbAFXbiV
MpMoLGxhyx8DZoxuCfZNDnqBh4O1BFbjeyNAQ836q/cn93xoTU/o93SZ8CVFtEQxGtYtitIq0KV4
3e7L97lOZ1gXDELiQ9DtFsjZEf/1B1L2RmXUkRHa4EuauC+DkwTjq8ITAJ9isXX+8j/Ex2BUnfX8
3eX0RUddB8Rz9stHY6YAKHW++1fs+gnudcFevVgAV+xKCMXlcvKXP0eHmE+yWSV4f5WPBnzIwjh/
ZoByp9w1gPUCosZPF1GoxDFELG2xZa+Eyyp5DZDtvXoQhEqKIYiLRabijFypMyFkhwN/aaEQNqvu
tPz118m1ED1Ys2XLJn0e5uNr6PDhSXZ6OG80SNBqHubza+j0x2KBd6oL0AcFu6b9vVvNckHSp6dD
M2bB6el2dUUAwIsmeUtQNOifzIq9CGh+6JQvlXyhI1Vo28S6I5o6BGp/dkeUC3m2B4vEfdxd1cV1
ublLCYg39evxeNd69pXu1SqdsgbAcnh3cFzv+h7G6WoneEOtT65anApHKvZjzoaDweYxejff33wE
nltC8oI/D54/Nk92YedD8mcGakYWLI/5EoJBpM8Opm+R/m5o3dPBcCulmC7d5m+/QTmqItO1iRfV
QLWvYd/f31yUM/SpglMJOGK/KmeJfj7o7G+S36H4RD6JmwcH/Ub18rf5/GxxQhn/9vTDwcFdhFCf
OBA+PG209t92JgdtCL5iO7JsfvmWAnnhGmX3FSs4OI4U9QLcXlUKqhENQnMQc1fiqn1XI2iAFe7L
T/2Wj6QvvlBIhnxeehz3JWb6ZiXpeGpX45L3zfp9B4f6shTdQYvIlG0KbB6DiS5eEL8r5xNYd1NK
aNPZPFxW0BpMySIfnUxLcSg8Ew8g084h/ApoIsHhHkxT0PN+VIhzDyxSip21KaZ3027Irau75ypm
K6pho/uDu3aw4ogvbMBHVhOJRgtSytsaGmm9FYz/VUnunRF6EUzBaFHFHJCRjNsxd10ucBdvH2OF
AvOmkAZHND5QA6Iiy9J0he1YT7C0BDPO32aEb/2bFmazmmdGzTP8Mitny0mGMRg65sOBM3ngvzsI
+vJ6Hr568nCoV1zhYf9hatld6was7fvGQ99CiKkvRA9KsjApxhimETTl4kRrGP5RIQ7P0fkMCxlt
hNx7m/J2wz5I+8Pflw79lenR392XrR3cv98ySxukJH9+8UWgOcsn2AxYMDVgjwYtuI5QBV6Ags0v
nQ1YiIyBoAWhYjqQAY/gwawQg8AC3p0CNCI2ab+h4Dza/tuX36f5g+D3uDfBUnf2T1z5AV7Q4f1k
8Bk+82wd034ywHdffCHblDu13mQGXF2XMTYgN5KCDKpjYgx7YBkneXtTiznJ210dKwBvCEPVxSjv
O0Pttxh6vX+aQHkxGU6z909Q9cmw7PZ6/Vu9nlXs+2LqJtRSnZRivR9nixJkzv/9vxJRHQwUstEC
Lt8rsNXb7PMoielM80m0oF3kVqDIXZOTmLEj8I2az7ZfjsNHcDmBtN9+O6awW35R3nB02UAhiMPA
BTR+423KiBOhKoTLQCUOKeHVCRS1g1A0qQEhKNYYwKtyndGKzWCtkco4FFyJ23WidYR4DtNWAcmt
KhnVwwhbIetoztniKkRxs+w4f1n8mvP1jgxnEXK83Pk//8//uyNoUpBmJY5rU3CnlWo4LXQANdLh
Q/IGQT9ffCF18eGIJ2x81vZjnchEZAPdckCOC5WCM7N6alu85Pt8MrNjaUq200++ASX9PY6/8s02
PpGCtQM5EEZcgGOvyAL5Qr5noOQHcZxcJHDj2928K03KJBmsgIm4Ik2+AuwX1aPAtsl87nKBYsol
OvxCxjNRr2H7qQBigXSGT7IdC0qkwUYwWqczAerXcMr4y59J+jXuKSrIFin4htisIGpjxbB0Egkj
QPVLDUzGgm44ofpkKOCSC6TDdAoAIMPINSgE3wr0NOzcxQv3inNHpoLiXAXDzt7mo4RJaluSkOgs
JPOZCoDqLa6U1ludCAb9txYtIWW35Q3be7m8PGMbuvVzLasfVyW0iCYwsqq8oQY1Ev/WNm1Ps6ct
TL47y+ZV3lKV2r/9tv3f/zQ+v3mxJf7d5X+l64cq5vb/6l1pjEjBAI2xE8lBk2Zk1BvDOtw01xaH
GUu+6liPZE4HJxclZ3XUT/uj5GUd88kuIvlZx3xyikhu1rEe7UIktXT0bwcSuQF0rEe7kIzT1DGf
7CJORKdO4KVdAcM5ddRP++Orkj+9Ku0PGMqpo366WMWDWMd4sAuo0E0d69GZOCNwU0e+sYu4EZs6
1lu7LMn+XIQe7AKekSaO27TQPDhQBuWt/axzCGdKw/9AvGnLUxNf8Q9iUcs6lz8roP3mIBSfTPpI
Mq8a1G7YMhk45ocLqBqkNC1YCfbIDOceVrDcAmqou4Ol4cRmC8PF6fKUVC0htZpzavnii88Qgsad
br6QtqnmLotBQMyN2QdAq+gCh6IvvlA8mxHcvrfb84CqYSmdzd2e2kgYCwSWv+WxmYdiquFIcm2v
+xp2xZ46sHsnleh0V/rcgSfcWwosGurTDNvmdxjkBNwVb8grO4NdKxBdzu8syKw6m7CBbZ/kENT4
8ctnyZ3bvR26rR8vY/3oMHV+Lx7Xa9KDT8hG5PLyHQQqZH+V/U0jK49oe0TnAfGrOBUi/aYKtXqY
KQbiBrtbS1RAHZgo8RlDgt4h79t0YZSNvfHXsmdppg5CkTGOTsLD6CQ0ijYbNUOEFm1uH4nIFzG0
F3WF6CD+BY8/8efeTs9fcDX7RNwZcQcTYrKjDe8XDpiRcIARUGUjAl7585tbHqxNNqzOpviKrOFW
cir7jvovxOMPNnZe2Ik6fDXbFuNYvh1xdPzIikw4fdAG7HpEWnpB90TrYiIqQXTiKkjyhcytCFTI
7YlpRDyUwPR5Oclg18L9in2T8sUlPZMAYHZL+utrKpV4wq/v14opht2a6UpVL1SpezccRx/+IbGp
30Bs6ssDJh/q+i1D43Y/vA9zE2gD+w58kMRRCkDvyANhHzUpn7WUZkWKEPcjN0VQWcV17bcC8ghd
5xpykmrLDRELbXEg136gofvhiLF6AjpONNi6RsIRZY22IF5sZDw2ik1JwKi/KBvV1vu7URfkkUa1
TZEnOrccnnbdybFuqexrp45UprDeObb56xGZcWz7q7fZTsDJsG6v+/3tXo2fYc3e02E+3K/jsCrq
SMB3kONJm7489CroyCNrSFOYDgaWGzj8WN1KRD1L0I1r80usTblvRpBz9ErubRj6urFvm2bVTV12
akfUyG9ND7jOc+1IYGIK8SFNdx2W8arjQUsnhBtic7/9hn9gF3z2B07cKDPgDZG3Wunf0DL+qJgj
pS0m+f1NWcd42Teue6NjFtA4jkA4StxJ53/587KqCrFwquP1fczWI0pZw3Qtqye/H6lR9rBExybO
xbiYZ9OKogxO88kkvya3MjMs+98gddquWjiB67mS+axnYAQyv7KDGUJke5d9p1cJuZNFnM1An76W
r5mRsEP7lImjoiACZr4ty8Gsc+NWbwWF27GQlIkD+v8/HvtWDl54IxV+SZT+Z/XLCWBk9CPFad2J
Dh3ldhYJ9BTvaUW8JzeXQVy1rFJhdNRPrSnUSTA6+rf+nMkzQuZoGCekJplYytK5e7ZaWOpGUcLJ
b9GRL3QJO4tFh5/1dytXRYcer6LOjKUTuasS4Q5C6USEJLR5H7Z7Q35wCwF1I+f0M40Eq7ul7JMe
5A1V/nj6HPydOFwvMKloG3aoxTdbX/fwx72ve/aZL0oHnc0n/KzOdxS1STQFi/7r3qYLihhXHJRy
CqCU02+2du708Nc98cMBJk53Ahz5woVHNAMAiT8ORJ+1rEwxwXMznY+zlWfjIM13tEVN8AzMy5C1
c04ymFAv3gKCWUD1IrdfoySZfygFSf0CXqkYOYJoLAjzPrDEYnyQlEfJ/ode9lIL8FajCHhvHVLe
CnS8/WbHGj2BrNVVOz2tr7popNy4ql6DqTcecSXGrDpyQfevxKuOdRuX5FgdKzFSP5JASWoojENV
Fj9Q0TE3vKQ6bjIkA7pwLiU8Azp5kIxKwSRKWMdOgWRUCWVPMnuBP1X/5h1uYZydVf2dunNoZHn7
MvxxXo5Mg71fBgbCQzohXAy/KE8GtGYUfKfIlzLKWWfzZVZUBUWXflsIgQ4uOJaQNFUUEksdRLt8
PiJe54VwEf0zUOqU4Ev1L2QTqwV6mTeMG20WToVUY780JK9mMVSsJf/oL38GcCCDZ6H8PdY8Y1bi
PG/M1ou8Wk4WiK6Jab+xeRdjCcJHjpmsZJz3naKtfJZLHYdoNBdIy/cmeGZqsSGfaLnklVyIX6ag
+b6LB1vsWZwN8un44UkhBKYSEAMvy6ngX9PjHONzz4rRmycMtAZtn6kXihO1HiD2VAHt1h1poHfQ
dk4jRJaCW5aTJSCXS3JDoIwW38SbbAHHbQ6TZVM2+aWqcptNDxAWjO/phPxeHopDLPa9yi4Xziz3
XmeWi2aVk/PQMEsZqGB04j3zDK/eRnVLXMI8yfNKW6FLOjKPg9ehTZILvLFCydojm57aVw2ukVqJ
kXYVpdJYmQdC+iN5WobjM8qRQsD83//LOWNTQvnNfmvzmViaEgatgTKiEAxHFHJDfuL9B8J2zseV
+HaCRCMO/rhgmsx6RPckwbia+uky1GvUW596P44Sysl1+TdL1LZWaD1FVBZSQq2chKZ6KEleHyzQ
kZ079rr0Tw6J06YpMxYpIc1wDeOfsoi6lJzm72Z8W+l+AxKAz7wLfrOzK9WSRsmo1glTw1MxDhtr
T9DOrm3ZRCehzaCcZw+vRtz7oRwXR7zmVq+ebLk42ZZANpP35BlA1urzC8CjfglYu2gcN4xrXWph
/VBCXLsE2shxXZ0iBoI7hrWqIvSgdbyNvtQpOFcRwObdVYO3R6dG5qzgcKH11o8TX+xSCbvrvLo5
jFg88/TFRl040Wn2NqHolG+L/F1tThuVPlpnsoE67fbdmg6o7eNy3ZaPy7bMul1M5bJUlfCt+mxQ
jZ8XRxydxuU7IUbn4pQByraueAN6gD3Mcd3GFlqwoswc30ZHnNPYORCqEvz+blgmVcWMb3fDAoAq
any7G7hFtZqED3cDt1pWY7KQzi3jFdOf7oYjMFoNGkXDQQ8M/LnBF4Lh7C6Tzige5e6KrXmX55dt
z7Hh8ZuhzYfaOQ8HH2jH09OGMtGqftk8aEWfl2tb2wTVYuYSrYd3Y0VN9meqkI/evMZ+AqXVNyha
CL4ruHakcCmOJfRJwJhNUEqbn0K9pffWqGY16pYGL++JCdCkrHKjE7c8fG5ePDy7UNPgdSrioVtX
2ucZLzHH9meCM8qAT5ttFwTkk4rbr8Nsq1E2yzev0CtxZxZyaykbeM6T8pjc/Zg/wXOQOcEHo9y3
YvsJloMPd/dd1XXHuo4yLoPU7QtfkHhXEt5dgnt1YOlj9Z1gMR7co4uBRlzJ1r4ItrRvGel1PIt9
x1Ld9qFx3GHq3FkMe3Bltm0YpFtuKI5Fs7YXdiyIw3a6lgGow7svjTeDM2GGvhISGgi5RILQQgbH
l2TiCGgJrGBzDTjgyANtuASxhMC7QFFE4IK2Lzo3ehCr02+fVS4Db9GAkHgKQuJ8ASZqdCdo84Ya
cOyyexTTzFc1wF3PX/5MkdOSfrL5pRl1jNzTpuW7VnvLgKS9jWFHLzo7dSOaZdN8Egs5v6nF0S0q
CIEyq/SALfrh1f3g8OgWUwxQLmyB3M6t6wQEXqwLCHCOFmPk+iBhWWVdYNxAWAqsjW+2yWvg3jfb
cDwVf04Wp5N7m5ubG//06b+G/50sD7er+Wh7BvnNx0L8GMIbpdSptodDsC4YDruzs8v2AfN1++ZN
/Cv+c//2ejd39G94v9vbuXXzn5Lex0DAEjhBkvzTXHDMunKrvv+d/pemqU5tD2tWK/Sqrvj4aSn9
g6//w6zKr7D2m6z/Gzs37PW/89WNGzuf1v9HWv8vT7J5PjYU+ZPiKB+dCTEWffFALY2cYANcLpLh
8GiJl15DvIOfL5JsOi0XKGNVXGZxNoNoC/xdHKUXpWh9Y2MDd/tE3cC15Kd2fyMR/43zowQFM7jP
PmonW/eSp+U07yfdbnfDKFHOQgU+LeYPsf7hLmJYCekPEi+cfZD137vt7f9f3fy0/j/W+ge7uy2a
4eQwG73JpyYzmE2yUX5STsZi/j/JA/946x90FB90/7/xVe+rXXf/v9n76tP6/1jyP6u6t2aT5fEx
xmBChxTNA47E//UpAT/+uLOmTADaGzjByxLyeYOf4e5P/p6Ux8dCgJCPi5N5juGW1QuoF5A0Xv3H
873hw+/3Hv7h8dNHneTB9IxKLeeTSXHYRXcPWfb7V6+e41VsJ3n94gn+sgpjHCNZWLyj1B1WEVaR
mi2+yMfFXCDt+2w6nuSibVbvdZLDZTEZD0Fpn88ZJd0u3aDIBp6iNhPeyO+nvywWAhLMSFfJYgTJ
kF/LQFZDM22H/LixURzZWCFBi5un4LqUmkGNAt+B3i83iyIko0kBeclkyeXhD//26tVDfCmEuyfP
HiUDOXfd43zxRPzM560h2iQPh+2Np3t/fPng+ePhi2fPXomi6cliMav629vszdwt58fbb3fTjUdQ
0CuFvqzdosTL57c3UyVPAt4oJSlrifCBZUoQcLNpsSh+FTIutLAl3QsT2N3Aa5bNko4E/gQRE11z
08MX+c9iOuW0Vq3AJBvC65y/DJk0UEztgI1vJzmaQWyLcd4Bi7QOBgXL5xD4LH8n6KndT5LfJdPy
l6yfPHj6tNfbwUbhP7ZHB0HXhAs7eCGm6QnExsnneriYckSMV7nnJ6NsMqnEohwnb/J8lmTSwiT5
ZVnki2QmapTj5DBfvMtzyC+TnxIW5LikEojHA3mvlUF2ciQobaFlcQU3lO2aRcVkYtmW+bJtlx9O
SsFiBnrNd5+IFy231DR/vxhyGBJRutftaWDnyynDWaKFnphbwq5gFuKoUBxPy3m+Py23BLGIN+Mt
UelAtf+uWJwYoOjhUPOT7Ez0FwBiC7lS97QUjK+cFiMDZPhPrEOqfC/p2W3Cf1i1moi5aVE+casE
BA/wqkg/BjlEpz82+PDr/Y5jF303z3MKKVMlYtoSycxEe2J4gjGNu8kfiFiqU1EuOc3mYmEDEQXa
PM2zCoLaILdgZwy0FivR9HEb7uC1VMH0OMJdQnDGebXoeo0GJ9rFcfKlT2ZikQyZgzx4tTd88viH
x6/2XojKgUXT2unu9Np6Wf1rVuFNCjE1wp5yRwY2BgwJ8SffxlcJMfe+wdY7ye87ibSOF+fYefIb
rhnRKPyJrSHeJQbcorMUpMdVKeT3uYBIlONXTkHae8RncytquRyubYyH29GHbQGyhk2QdASCAvxr
F85Q4D9RSq0etxZals0MMga78v7qhWC0SfhRPmiQKAkSWI2HcE/Uwn0TQhany8XR1p207fWIvb4f
5bNF8uwlbiJJVsGbwPLLwBVN7zxHKbioASzQa7Kcqhxj/eQ8BtxF2qYVI7ow0QrIAxLZqO+R2rXI
8yKRYIg5oKRhbXcjAcrQc4z4QcMrtVfBGulLyQXnfVyMFvsCWyhTHWi4vAkxuCfRVxf+tOZSCpI+
dSZGHIecNuB8nkPAUHf+4T+46hHzLQvg/JpEQ9OnpLvgBDZEJTSSnIvaXdi3g5PF3UkJMtwbZuIS
MAuRKFss5i1RopOk9Drt0NKvhc9DQgTgqdjAy/mbBAVdQXewvbU4g1tXimFAYAwSem5sLqdvpmAC
cZFa/cRHa0Ztugp+5ZYDEz9ORIsmhuM0Ns/eCWQCyXZRLm4BSXgU0MICYLIqDi0yYKeQ9cW2IZ6M
d+2rDQGWlICeTT0T6LBmVRcV2t9MR2JesncdXFjtq/WcTcFn7P1MMG/xJNeFv+xFf5bELBgF7XIt
Z9dr12x7opK54YlDUnZa6f1B84nyEHYVg1VQ0b5fRDR9nsoY1Gnf4uRmWBqxZKCUKLFz4e1BsjxE
CxwIWK2QUmnfFcXMOjJck7fICOL9lAukB842w+/t3WMS4llOjzIglFfO7JULeb3y+5V9yIBR9Z1w
Kb8X/lCHOHL3i6LtF69RrFCzvV9v+7HpVsGwajEj40T7sy7rfzSactqWwbOibXMBr21+X9e2G6Ar
2kdumU55XTnt1HUJnHIIyqB4Z1DE60LVq2t8Ua5oelF6DXOdumbRMTraJkYrBU7ltgwf6qmGAoHV
UA0YnwWIBuu5DJ9qaW59lC9GJyFebct0+XQ8K8VZKvHYaENuS2JFqqOYabliOUclQHpuaoIuts9l
nxf3z5WqrUViJG8x7bYhnkjBYSCFVFtCEk10rBesaxmce5hNH4xAWhCbSmp4qG3/jJKZX/p1lc+3
HhyLTRJqKJXodq97s3sjVOHftx7Miq0/5GdyY1NnqrZd+kI/Gjs3SjpUT8vpPPq2uQmKkqBxa6Xk
hiEkkM/EvJRvnK1vhDOmS8Nz2l4hfsigwkqbhOLl+dFm0jpHwbi9CSAYog2puQRttVHnhL2SrCmE
zHa9TESAyU0/bXeSSVGtkpEUjFL8SaQ1mehBZ7TI5vPsrF4yeqTloKZyEVb5EFKRNeRUyEJ10pFd
WEpK9uvfGVr8KaxPgQEZN7AytIVkUXlXrjPQsC/myynrSbO3ZTGunIaneT4WYFSTs2QCFtx6JoR0
DikgOFlIlbw7yUFRtJxMZEdwVlXHZVsRlHK/MJiUixvr7FoFwbjIdC3i0upNY+0NIypIXkaI/NDS
3Tpy29836mpETNl6cWnBsoGIcLhaRHCaVfFCgzMmv3qtyg8b68l2a8p1TWS6NeS5vw3piGY7IBnp
u69PclG9XBRQ8nfh7meSnR6Os35UbvogAghdqlxB/AAaJMU8XFIO6aq1dck7BFO9I74/cq80xMCZ
StWmD5TK97DGNinvHi190YgBYSgG/Ldd1zRe3voNm+JWbbO+WPp6Wi1ncBGdjxPrRqafnDsQgNBJ
GB6qMMnDRdWi0MksciHmCsSXvrjwKYQiBZBwW87xKzUTvK/1FJhoVgA3WdL+ARleUZVH5fw0W1Dz
XSGWgdlVK/3PtJOkX/Z6/V4vZcJl/eaPUBBxEe9ZQE/9dRe/FtOjEgQt+1LGrcHPAg0tWVPAKIZ+
OhOshpE4BVDhghlJFdZM3+GXocuvOlFYLpEhrezAKozMhlnRW6gBTapLGA1XrAVkH/vZ94YCG88+
XSSDwYyASErnCdybGpDu95OACH/Qr2dMsmBQawzgF9Ol3uYwzjHhUlYknOIHgwvRzuMVE6+NQmrZ
AN+11pBX0QhEntbyWgTEXkkEND8YRWHnsgoC0NJ8A8HyKNtCioZikZ82Om0RlvoEkXO4AtT0/d00
NfEiCqjH0HnFSHkSwr7x2T4wG0ixsqaow7bx1jntiKHvWw3DsI3nDbOfZtsDLovl4qSchwZBX1LP
EMJcv1jEAJ9eBFToCD23CIDTT7tpSBgToeVX5WP4mtZdL0frF05Vewz41RgCPodwjx+GQD0wAHzS
OGcrLsUAbQjoaxQEXTnIHOhzhO4vbLsRWFVSw4H3yNNEIGAM+xAoPNK2Pze4Z4HUraBAoM1m2iG1
fGRXBRw6W6o/mH2zdRgH1vCOTjTwCDUxUg8U6KqcZMkcl68F5XkXWJSLbDLkmHjmXoUfKJwg6N9W
rCE6BtiVH9i7HdvwrWJXaTU6yU8zW9sjx9Z3gTCKIJOCnR7FEPKuNKTv9CjPx6KEwxiV3UtN06Sv
At2i3uhAJWgXwGO/LoGPwNSBjztF5XWJKiyzn3HxZtgONCxP+aphfgEN+tfuccHWKyoAa9VCRIrR
2pMiFIHNzh5z27mljw5NKqv02PhN7eDqgGnFESA35svBqnQfxgzLV2Fo10eucR+B3w/LctIyaa/d
bjyLPOZQN3ywbzpyeVmnxs0vVlL0qiHGOnSu5nTHzocPBgBqfVSvSt2z7oq73AozAGw6Q4tSQ8u6
pL9ZWNXVo4IY3vzNgstaSZOt44sPsOT/Gmtb6U3V+FSS61otSahBQw+mT8X9xL7+udjwJStLXunA
ft9WG0u8GDDHtqm1QFFkP7WKoeRkvdmwFKzsgmDYHCnPz/46RrPge8AKsX6SWm4HKRrSTxYn8EF7
LrAOJ72KYS30Kj4ZndvfqV9Rgn7YH/WsRpV6rkk7uLVahu8Y88WzfKfvVsFX+KvFkZNY7bkUh0IQ
2Ae4RLaU7XUKac7z03I6eAVJS1zr+6xaDKvlSOzdVd/QhjEiN2rddFVbT5496oK+qZW+hGJwf2h7
FPWTzyvxPwGLqTFXgqSnR297lwGM/ailsVEIMzoOOeBLBJ8UD6bVrvUyDkyYEFPMKVIm0dxqUQ2z
SfEWEr350MlCP5fFVGaLGJCDRK157JfJbrfnDoOVDZYXUCstj45AfEs7bPE5SNUUIPgzIeFfC26x
KRN9YYBojaO/EequUZlNoDWzh2emog+bIa8ne+vA3jqB8/AgSHtWQXM5DPwV0gnY+Q7oT+jaglVg
irt0JY7mEJt0KhCIa3XbHJOYOh6VQ0Kwxsb54fKYjB8SsxJ2o3Vjh/koW4odBdgmzKphnJ6aU4ZX
YGKAC+m5FJgAwyRFoqxLV2ftwCT5mmJrbbe9A7eow7WDCmCSW5Z4/TbJp0r923bVSspmFFXCtKH2
1p4IQoWYAtvlriVnZNWlECKc2zaxjloWs4c6NgyqIueQ3mztT3HpX8fyJkBaiPl2gMsjAVKArjGZ
Pn8udo/Px2pao4yemzTcEdh5K8p1mzK6inceAwHoS4TEyi5jxi3I/GwonbtOBTu+0RPfO5B0unUb
f/l8WTmwJdvJDcGQ21qX9+4EfEAUidFOIfYC3Cw8GxSbFEcQFB1MubsQFFftC7dED/2QDO8ouHGc
5buAq5Tf7bvk3sBASsAtLWY/TMOy+EU7WNBCOfT4ZRLCoVeXL7nUWor64UhChMQTYraZFsGVMx/3
ScQQ9cLANV0QtYsDjeFaFbl1tNs16GpIufVNBRBqUO9G0FsRqHgHyRkpG34ZzfiOi07XBg0jSbKH
4qfYCf8Q8R9mo+GxOEbMP2T8t1u33fgvu+LPp/gPHyn+w8MEZ/hT8JdP6z+w/in+5lVCwKxY/zdu
7HzlxX/c+RT/6aPFf1pOFsUWz7Ox+PE6fpzNFmgnjpl4zpoHfXFCuayK1hIJicLRX+2oKAxq1c0n
+XFZDkejXVl+D988fLj7gADvyBYowEt9OJRriXEi1Z0KckvjKdD37N0UAy4U03EOl8vQ24zj4Cl8
QxQGzj+ZyBVYF5FDqk0tfNVrTj+IUnTIA5BGUu58sI1UMzUinJLHOURPBysEy5UN31bBoxR968rs
nfEzkxeeA+uN55hXFtxnNHmlfjNw6CDZP2Wkg05zWeWgX9GWidwcHkS4h2LcsTtrN4NR0sbAo/IW
NWcdsjt6whpEE+G2lRo0cBYzF1L0OBbGCkTkphsHbL/voSN4RAsiwaYyaZ/BzyHdxHOPr7EmmGIV
fK54XKtqC6BAq2T30W6oFAZqlVNUQBYdMbNiS3Vb62+E8V7OPNW0GiVm0za1q4uT5enhVBwjhzNx
5iUWwGxiWIz7ZEcjIDw8E2dzy6CVmdALuqNZnOQyL1byYCyOh7plHA/wKYrGbXGhyJAdDuAuMDlW
Ne9w5WVAHQtxI+vZg24HbVg/CXTXLf9x/ogPJ//d6t325T8ICfhJ/vs48p+V31Is+IcQ7elmtxcL
ALh+4L8MRaK8MmL/0au/r+B/HfiJn+rCAKqIf+IzBL+JSLaM8f/S8f5ePnv94uEeuEoBIpiTbAk+
DfG/tm6mG6FggBgIUBc/zWYYFxBoZltQ5TZXF5WfPHn2x71vh9DI989eYiPhyunGo71nD599u9e0
s+O83N4RfVFMLB0OkCetLtjgg6RS4Qa51aRZxMF/UcuiJSbh15xu6MV8T8pFxbf1FhgvrCBJUNtz
TQBnDHJJUJnq6SqD3qnU88ZLGNOvGFRbtGC9GZZHR1W+QLuADaWMFmQeuLuV/jZTyk8d87TBbl2P
G98uGM1RAn4B/LklGuMrGvNOLuLcQpbCEj6xVPPxcCbmuZi1KGWv783yRhzWtFQVA51tt7ENvL6E
ajHPlZCtdgRgiURlLbxzkipnnCGE6iswAmAY+rDfTT3gKVNuWgs93a3yrEAb/gSBs0vvYOVAwb6a
bKlFaR46GBTVmqzDpuRYqIPlIvw1vRzEYzECNwrdvTRYh25pokwL9SAFthAGsJ4Kmk+ZdOpG/4KB
7HtW6tL5Dz9LO2Y5pzJ9ZkvFQXPXfEelqxbUC/xWk2fEx6oWoxuGCSH4cKrwapJtGOZngmtYJSQT
MU3LmWOY5eS7QDFmLKHS/Mmxb3PHvuFgm1wVDpQSQ5X0Ue/5tPF56DpRz+tHDQ5ZteOmZm0tqTyU
Bd3TMKcTu0XimjXj4cFHuYhYUiA/BWN1jxfRha2qELGvCeVJhgBSKDTsxdiaapay2HdRlLMoETKs
gzuxlWk9tR0UJtVwUrzB6BD6yS41gxR9oi6Ukb+HJ7PMLCNOlsUYrG36+vdwNjJDTQie8m6IzthQ
SD3YfS3fFvAV/hhvR5NyOa4wggX+clt+K/DP1j5982l4apZ6JzaTYTUjpwx6Op1VXoljcaBRBeAh
WGqcH6tC8Nv0HFlO52Kq4bP8aX+llSp/mSsTODITkOB3nYQsEqUbEU9yF7hu1QqwY7XPaVLVrdmu
hFQlemOPi0D3rjmv9CWeYneBvR8CM8ImQr1VZEoRKwmf9UrCZoMgITjY7nDnZHhKQQ/gUVbFfmqq
wnejKjxusIqM9n4A0hUETH9s+uA2qz5IVklP7O46yece56CXPGZ8GBZjKLSPWzgQAP4Ah1eq7/jK
iY/k5nXgmmxhcctgSyqKmV83dnmiY8cank6K6UE0AsUAzR2PtmPx2d+ave3AbBlZdR/RbRpwS8SB
Bbf8LReSux9Rms11t6NOAvXIhrdua1L9jJu6NdOOgxpOc8vpY3+GD/PKzWfNDSioEq7x503t6dRu
jqHNptGG03zTabrxNN18mm5A8U2oyUbUfDNqtiE135SabEwXltr5EtvMZbaaZtuNcikNbTnKKhbN
+wMdp+KL4ykPZaO9kfOqKILTh1tJuZyOW2SiKN63k98nO72eGS+l6Ya33qa3cuPT4MY2v5UboOGu
G9kEG26E8c1QdxHbELVlpeSWAc/gD75NXX4bQt4sqmn4Y7sNJnFef7MZZ2cfc6+B7v4ethrYSRyY
cJOJKRvgY9CD39J1iNGjsoN0HRAXEJzzi+MTMFUHpzd8Xc6ndc76khFBl0oHEnTTb8D81Ao6sjbP
c9HmhdigfGaI+6aDGWNnjeEHizRG0GVRgr1cJ04MKSGOkqhY8vcpR3xk6WD10bXu+GoELShVE+p3
oAw3In8GSgxnJ5luh58+STPXIM3gUi+mY1rrc1b5kljiZQpg8SWmlw+zGV3PuVsIqX7NwgH9r8EG
zqHfCy0CyXpOBPk4LAG+h57MUzolmhOiapk3BgFGpuo25WU8CC2HyRY+yWJNVQJndaLYcV7ida9s
tGpRJFaSs8zAf+g8yf5B5Ks7SHZugQbltFAvbqFAFpG21KWlEO/Kyds8yRKxcWTTRHaONlKi+SR/
PysrjAN8kqsUM4sSbn8xCAvcyOacMdwQthB0mWanXpesuqQ4ME76Gop2ibLWLwJ5Vrti8eOQxXv0
dCE/F3zVEeOH78BEYR9i9MmaFxsromZCPE7j5tgKw0kgtS8Mpq7iadaGz6wLl3mj20vZ1b/tBw9E
izU2K/Bz6gTz5+isci9v7PTq86g4OXWscIPxhDqByTyybEqIooF4ViTUWZVMZ71EOmvAddW8OeFx
tMw8OZ3k8vloQsslPBDye3Phqbu+vUwvzVLPcEiIhkc9qTWGYJI1RzbSHzeJfzjJFuYNL95rauKY
IB0ZX2vi7ImacQsE/BixPwgfI+22IXZftG34uE7bk+wwh2COwGMorAA4E5q33OKDEAQk/7NPTXhn
CpIU2ALBDxkcC72r61tqOzewyjL3PJU3yCkbmQDKkGfLe2P9QSw3+ACjEC9pNGB9lp6LOhedc1Hg
Ir1o+5e4lbLQMSjWDHhbYzJvGWJ95Ax9aiKcuxD6aoZFdMqrCDEfMlsfozhcLZ6f6xoT8jVIxhdk
8x8nF1+cV66fhM9MFzsTjQzLubKsQqJky3kvJAvOdNAgzAo3LC0XW0bj9iGNwv2imOznZWqFAs7r
8sS5hLyNhnXAO9DALr0IRV3imidltcAUGp8NEteUL1QNY1pQVRgDuSpUIBK1Us86cNsN0hTL4GjP
oTLUs7e4KjvKRd/HxZREVCGhOO3/zmQ8aAZxCJl0y0Mh6b3FvRHag83TaGZSTN9UJNRlU6c5wF/C
yM3fYlLecnl8gvL3uBwtTwVrE+3m7zPItYqOJ1in6iZPwfPAaa4Cv05TdheThV4FCazEfjIryBkA
JZoEpgbZznJ2PBciLXxyGjSGodL4lSjgvRRDF/sKBLmAtK1ooeukd6WQwzyZQxnsmkY7YNIBH/WF
OBQMXNoQm+E8O4bxD8QOBNuRaK42bWjzJCuGBZSdTMI1gnKMoazCvj2UVqmJDQj1Zqe54HSjUGR8
zGbR93JZBErKQ019/HwvJCosm/rTvsolAUXprgV+BaZQ7MxGFieDtYRPShs1mQowxPM1HaDaKxKU
Ro9QjdOS1hyr4L/rS1Jac375K6cnrYHsms9Txkgaph6N78x/+zlH62D/QMlGG3S5Msso7MBmOGTD
SDEMEtrExHNr1MEUsYm0w/XrQ6CCCTh7J8jZ3ZOhroJrIMjfDS7DxqpWOGhpAosHJa8o27WGakhr
2E7Sq8Off/IEKSl4br0kfkGMkaSmTnG1IHkHVhckddy9DpDUAbI+ywCbHVv5AwIFpKVx4C74UuAp
ohB7feasBuk4YU4/vHNGIksZu3XoBkKWoyHaoBs9KWt71B0I4W865EXrG+/hh5DpHvKQA/c045w/
Wrr1jnXoN8/5emK8GZBAGx6v0ipbHW6jRx7r1CoPVtJU2Yx3B91C6CUVlTCf8XELFR/anCHaFRnK
RKOz/S55dQKu68WiyCa2a53sW+1Hp0vxDwbQFkzsLPnpJxS5fvqpuxE+YtAoK8yjd5bMhAydzQVj
/uknwN1PP8GWX1EwfyWo66aOijnKXjaOjlIJ1fY5IOPCOrXC5Q0o4IFht7ABtMUwfZZz4JznWqk2
xs3VVO5RKxehdUBNyhfGAfYYowLuOMHVJrm8UarayTccFBDXhmwSHqj2N8lt90CAeR7s4Wuic+0K
JPhQzbHdN4JMoqWHPfhgLmIsyedlwFn4to3HZl9thWOL5dNuNh63sOF2bPEj7B52NYa/NFG8KCf5
HBa9qHjn9s1ejwDPZxikeAfMK0hmu3G7p4VfcgUNshNJPj5H0cgyYhNzqhI4e9yjKGdbGqYDp0MM
Gg0ayQEl/mJDHViVup12exXLsmcdW97vI1kd2CcqItTwkZC/hU+A9NF3g/G/WU4v7mSakUUdv8Tm
4ZUdpeffd4RlT+f7sSMsS8/Wv06QZdv2REVcljuF7cX9eZW0Pu/eFKQA/7YdDYQt59Khm/Lciqqp
vtRWF8R19YMrZIWm5GrRSnkePsV6/jCxnjV6o+GepSy1PDoq3rM0Fc9jE0D36tC81PZ6MXkdXUVt
XN5z6uAi/TuLZu2asPxV4lcziawdwloyq2uLYu2dF9y8h3xic2NZy3qRNadHKA8UnRrX0U6cobb/
ZkM+y1XOg1HRn0PBldQew46gHAM6MB/sxbTudKgzGliw2eikFrHhyhoxHQ0Me3E4IMRq+hSpIgmr
2xwsrlVhn4+3Px9LkZZDRtn9NQE0QlZU2KIqxwGshqhq+r0emuAmJUn4I68jEsYj0wjGB69Dok9D
5JtwBRIiu3ArkBw0OQSTvPVISNdrQEBY+PL0E4IxQj1Y1CIe25+jMe0YfV4P5VCDlyMcwt9l6OaD
R5OXjI/jqDOJ8xPBXRdqHmLL/z2FjZd7AtmZidLfZZMqr4sszzUuGVve3429E7ExA154eQnuqjDz
pnjYPNK8u/l9nKDzckHlVgiGFHW/HzEEvYt2Mwh9qJJHOXAw3nApxy7lI8ReZGDta7zpWJC1w5Xl
mlR18UVdVd+eIEDmBEF4BqOU7lI7b/TtaGGHx3j0zttzlNwvQ/KrxKJmVH9Zyl9B/UpaqqfYGO6i
mRMCM4x0csUJps14BYySQv3ppT3048wuQfFXnVwpzDScWxtvNUkxKKUpJ3ox130n8bkJttpumlZD
Nf53k1QjFv+T8vScXUsfK+J/7tzcvWnH/9y5dUu8+hT/8+PE/+Q4hspniWMTCs4BFoHKuCoRhHGd
oT+xBJiMTYpDFe5dPKo4n+UphNfc2Nj4du+7B6+fvBo+fPb0u8ePhs8fvPpeLD8o20q3BWPVxKt/
daG6kNZl3WfP957+cU/U3Hsx/MPef9Q2UuUjwT6qbSMwpDSvM1p8uvfHl2D81rQ1zlQaaOkRNNW4
HcwRGmjl+YvHT1+J0b3ce/hi79Xw28cvVrUk4+iLRhCC5y+e/fj4270XL9HPSmZW7ci0pBcbcsgP
H7zae/TsxeO9l8qCMj3Op/k8m/CFQHq4rCBvtHTjTRf56GRaTsrjM/kGDFjnoDc8RfmVXlYw9apS
NSry6Ui6zaa0TYgnDckPz74lIJx01R0r+evFBqG4pjSndpUl7RHqwSXpu3I+wViD00yGF9Rjtcfp
jVGPzxibGpce1ZMHTx+9fvCIO8/mFNKQGsR/sYWjOVXGCIfY+hQhnJbw7wzfzJfY11v4d4lg/2p2
9PDZ66ev7HnMsD3qE82l0gzbOMT3h8f4L34dZfjvCf47JYcR/BfLj341oJae2gzz8SH+S/C/wX+x
DgVxLGhEOBby7aXR/YyG5W+w1gTfTN5SAATZ+ilGQjgl5/9jFyNThGiG8M4mBo7w67wy8JURSeC/
CvYK10KF8C6wlQXCsniH2MU6S2yFwg38milSFYvywYuH3w+/e7z35FumwGIxyQOxKuFsDsSiJ+nl
sxeCf71QC3OeT/K32XSEw5yVYl1nc1Kzp0pb/mChSNmtbpZBO09qLVcVnr5+8uTBvz7ZM6GNAAlz
cwr5pi/Wil+Lt8t0E42oBXtzHW4WlojyZ71z5wbFDslO82qWjeimBXycND97u0NOp3SHLAPgW2W2
xOZFhd7k+Qzv6WQXN3oqkiKqUIZCnCPBUQHhFsje2wVusBLnX2ZzsWfMF2dKA2Vd6AimIyTBsHsO
WyUcpeSgoobbnZNPzOb2ZvtiuzqrFvmpfbuyFuYxyL+JepkmA63yLIUOGPrkU4XKnd2vukLG7TKu
zUm607vTu0z84mZwSEWugiQSSzoQ5Ni5Vw+FPA4WMdSiqlfqwPQY6uPuKr7VyRgM1vRYNSRY4Iap
EZHnOYlNaVLjHOb1iuDv9mlQfe7dsevrMHDi6807RlUVswerma7QQ8+rfK3p1bm7155bKXRQVNBy
rPFv79j4XTvG6wmiy9DKecuejP4cZIv8uPQbQWFA4NZ5Py4hwLDbuDibTgRBDcNfQcwFS0iXkhZl
6G2QUsDAaXh4ZnA1zcGJOXJaeacx4FMyA6sz0VGqilPASvJ3BeK1aIbTtHyLuUFM4mFuTvjHdDn6
2d43MrxbGKJVgAYwSIGofIzuNTVbwW6TrWD9YTdbLTLrUbJYzib5fgBlnaTb7YLDDiuZZuVk4rGI
W3UTTQxCp1qBAR5mVX775hCTyShEDMVJHf4fKD+bHtuFd4a34oWL9/nEKCmbXQeL3y8PTQzChUjf
EDKIOmDn65sbIL7mjcSxiOPo9u8EXJqZMcdCdDqZtmTcbgiSAdlyAOd2zHsyFdNmIgKK4nR5qsaN
uYb1G99ypJCXKJcJkI+WleIrRf75RvXuOP//CJ+lkcw5AHxBhsmHYHeOTOM4n4NK9JxbuNDhbxl+
z1id+rynxrdGn99AR1TtIm1HY/jD4KPYpjxIokQ/EgshHLq9AUKwSp5NayAbleV8DObXeQ01KFJA
gcQgBPKhAPjx1/XnR2gwRoonZIV0AGNttFzD1q1A4jwUmDgu+83gMhN/mC/egTm5IjOkpAgtWHHc
hyUeUrLJcHRSFqM6vFMB2K9zNEs7sKXyKKXYThZNkAgivLo7VkjE5qTLe3dSvsvnLR1MmkrBsPkn
m4xLqBsAUFip6BohbfGuHE7yBWTkQtfN2lX1t4cqaVggntvgV76rslPgu25RZZPZSdZabxWgCz+0
lCW7W4SdBLBTh9FR9XbFBkC0PMTAbjGm/8ExjL1Lk30rLIg03WfUz8RZs5V2KBaIWfjA4f80IG8X
gInBL229FfDYm0LP7n6JOLSdgoP6udXMhfh+epptVeAJA4YiBHmlNyhK7bdgMJA+NFRNoFD+huMl
uSTndh9MCAJLZOdLLUuKUIeKQDIcNc+K4jUBobpFpmPDnPNd1VTqLAIjG2GRT8YUYRMpX0+gac6T
Tc9aWFJyl4CyCoiByojv1GzQxtbAWBxgjUMKrKDyZGLDjVhUUZV3bvd2/iZZk5Ptw5oRSR36WAiX
ITlevejLEXz2I3/JL12oJzBwBAZeC2Z1XRlBIf1P0Mh92ev1e73Ujt+lhxYJL1U39scvnyWAc9fX
ODRRynwUBeMhHn85iCV4IVtkH9ADYThpDAXtmveZXjtUo7VWbiWPSPcNKmWoD4zpXpiWxTIX74Cl
TeW1yR8E3vGc1rZXq0yeKEu1La2H6f0p38EEhhVcscHKmtrBVbX/WVRbVoeXAPyqRYmezWCzmxJd
Ug835MxShgO26bGrlHFeOce1V9bjvRG5udkFkws5pZlSt1kqPDUKpE6y9XWvk3zdc2Az+7TgjXdq
Fov0qgYout25I/oV/6gZltRGIo0cu+xPzLAGjl/WErps7p3nEQRKgEIsX41g3KsN7PsaUXuejA+G
pzuosex5p+uYI3mSMBVJZkHzPZt+1GlXmccdyaMtbQMYzqzlWLc6sIqF2sK4KhxxBZ7NzjFopAGL
KTE23FMivDVADStkNOoOwIyF0lyxfHE6lIexlGjt5q0YXZfrxprUUHcbUU6uI2kQrQ74r3ZDkSxo
oPidGeUByXXgu5wpUh4EnM0sihhYTyq2qCpsDm6A1+rmm7YJzfR4YE6W/uSq/Ae2wkitArecWAm3
e73I3hIozKfmAVbS0UntC4VY506xFFlTrHO/cLhv+7Ii1rVdCnruxbv2CteOGq9BVgyZsiR0kpt3
6kcry/H5YwDlnZHC3Ur9KDEMMIywdnhcSva0Y47M0eDGunOKQZ+3In36RWXHt2XH8jiDRihNZDz3
MmiFgKeLX6N0B8Bet2iH55r15Dp5uXUJSc48nikznYbsGSH1JTiGZhP62UQLn03DbysTEv0QLuAi
d2/8SY0TnsHr2agpk4SBumaMb+A8alvuQOBBhTXj/o+EKsNqJ4KyU0zLLNGFQDGqrH41pvg1jAp9
mumkLg5QnKO2rYUJDNCAp9OW1Vi7vdFse0fEI0wS6efc0AWF5pAjP5e/lNMpBcE28IsvDAnLRwWW
WHmu9eCjniKihwTDiretvwwxyDZcKVGIiJqp3OXLH9bDYHVQBRnt9NdBqw02XBQYLV0ko5Nsno3A
uK0G0zLypQk1mbqhGEwkPlC2YSr0Dt07r43jopLy9hiBegS8ju+a5bzz9bVUAKnp5/dEACGNEH9v
2/fX0I7WO+nWlP6Iovial9te1/w+2rX83g5dhnutOd+jrbrl2vZlOrTraYRUJ1As2jJ+bJt38PWN
LcpoU+ITz5s0JHAPsvJ97co1K6+/gGXt2BpW3wcWlJ42Pbgc5CK2Dj9qYRgmlrg4JPVKhS8/G8pH
WPK7vbXVh9xuUA2824tofoF/awgRakP7ySYh1tzzlZGePQ6AzSfXAAXoEp5JpZ3pQk4CoEY9GLu6
bVa7LoJUi/aVD7IZ4DKidVvxq6bQ3tq9WWxJNGGOB+qkfdnpG6GFOJComLBDCBhA4TgDfSBaCPDE
AtGdRtY0xOfQVD0EJpA/e5a3hqstWd+Yq5pfuRaX9bnGsIqWVWSzDg0Y1prro5labEQD0mTIMGOy
/NzAn4enTdSX3Fz8dK2dLkcL21x9290vsjl7wCr4xYhwp1yxdt2by0ss4hqqirbehLyacwLX+Pw6
+YCLxI9D154N8jVStTsig6ZtoUN+iG7kqoA9VNkeRuB3r8rCxtLWbZlswNwA1x2/AiJ2c0ZipLw/
s85voJ2a1RvprRDbwy4q66pwXXjaMUnI1sCaATuvoJ5ENPq6STJvKadbdL2vZKaNsDbiShpK2LQG
eFZVr/BMMKBDm5PIshrw347L8Qb81/jAK34gfxiNSSl/oH4ZairitwP+2zFDGZsMeeA864JKFh+o
Xx0jgiB94r8B7WjHZUQDyUq89TyQPwyEGqatMcWXWSakaaPjuV1IK9pMTdsqvWW9rhT7Cegpb/R6
ukMMs/hBlHvYfQPN3molt0r2YqsC2SSykTYwYO+6QiFo1bhGnSBDfd1qQW7W0Qyy5a57OuTXoqn9
g9jIjKqRlE0Rtich4QZMQ06Mk52URzTiSm8bbF+MGZsC5sVGziYIOwpZ67X1HAbekaE60IJoOs7f
d5QhUT5dnkJiWGtIxmBm8/yoeI9JBeKj2D/HVi8O0sskiQpZOlC3FzEy0HgRo7UCvBZmOD2yTLcD
wOIrdH+bCM5cDkejXaMG5tgwy8OL1M5y6d5pWoNpKbDIc85J/NCi/sHBjABxv0N/4HmH3Rrh3oKB
ZsJ3nXJztmxgYplWgmj3rz5jO7Kd8pEmQ2HASxzEtk2jEymtpdnhSDCr45Pi5zeT02k5+2VeLZZv
370/+/XBvz4UYs6j7x//tz88+eHps+f/9uLlq9c//vHf/+M/ezu7N27euv3Vna+3hinOiGgQ5DoT
juY01hVAn4qFJzUY5XRyltCpApMaHxeQinpzaxMFzs3hpit5m6Pn6MG4BlcBoO3VeDmhV8W51aAZ
7Vk2jHGF7cEGJ0NRP/0IGmr6g+BaYKRirJDm2OT6npWr3s0chxBzudlBU92SblhTwwwh4Ga9DW57
NjKHRovW6qphWy4QjgDsfA0vtzp8eehotugsbxjYDi1JxEvcKuUSz4VGcMJdhwcZwAUrWIWlwAJi
UwCflk/OJcCUjjwCzBu9RnDqGkE4b4fhRFtNE6P3bNCbz2cAZeaFSAhSb1NTAcatXgNbv58ArBgP
LJr3MxTRAh14S94vCZvQAP7xbSZii5nF08iqCDQgz20kzmka0PIcuhR1zNlWUpzfHLAbRyrXbcJH
PAzcuWE3yB8Ujdy6deNWoPHA1A6sd7VV5HQPrHd2lbYZRTxgdoYsR+ygRCYSEbgH0ivMEkE01Mj4
TO48AeOzbCF2wUwQLlrTcXlq2zmP24eB1UdyBnCADnNS7jTwbfnHDWpYhr7PN2ukkF/Yyf0ekF2d
Oja34MPgbhNm1/R4GAbdPwPeaQC8V2sd8G+HoY+7FzYaSLw67DHSg7DB2OoaCg5zp7d7MzzSnduy
3wYjVg6Slxiuqgv8RfpVrj1Wo5V1B7q7zkDRufMyo8SKOMTLTqdsIji+m72vb689kcqVA31JWd/h
qTi8EAsrFBxG+auqNxCukEZjXYUGNuToMCgehGXVi2/ghKuDQ8RGQGVtkZbeNdHmEjwMQa3YGkHs
6q2CGh/YMJk7xTyqhONNHcJgaOTV7PSSjiAkuqQiUIt7HvVGwCskLcfPGS9PMRcqZjNM54cpJpY7
ERv4xCQ01DpxPC3MX9eiIry5YgIORzUF76KTKSs0oMnToqrg9n0f6hw4McYqsWYKzLy9YahEZOue
WsQHhHQYJk2ZQmQtXBA0FztcfQpSwVg84NQXujIzAtK07Yg0Xk31xaqJYWpig1Wd2SPWoWJo2Ol2
unrkekgrV1PAXkXCbgOiXjfGv0bP6kngZDHaq7+10eD0EFi29jzYkjqBtUJIV7gbhFBvXM3I0Q08
zOhCKhxRLZSqFJ9OGVD92hIN/bNDXdvho/qO6iT0PdydOnc07M45cvv96XOrZJzSfCUCGPiWRtpY
SYwrjtNx2NgCTMkjng2Y+iIGen4RXVVWA+vdZkRvMXgrVBuHXjQwngH8Y9z+wMY18KQbvtaFt6l5
sGar8UGdx589KGqJy1ttwSXVIGpTHmoF7TTNJlgKHNRdR4Ua4vKpvtb6p3+g/8LxXyki4bZMHnbF
QLD18V8hBOxtJ/7rV7vi1af4rx8n/qtgDmSMpDQzHMQZcw0JAXP0BpIHQujXf/r03z/S+kcCuHoU
6Pr1v9P7aqfnrP/bt2/c+rT+P9L6p+SGW1V2lCdzjgVtcYD8vZDn8rE4QWJEaHCUnJCwkLx+3Dwk
tIzrLLMqqhcQ8QAbWJzBLi0rP5ieqQSXRubJSG7LWIoXzgU4xEzgK7JqiZG9sfI+PhEvvFRgKmSY
zmcnQD1QIXSVikrqT/qkWHEUWIhb8S0dFxUrYOwCmBFM5vfo49hCJTgHQrwAxdEPfmeHRplOJ1iG
HBFri2A3GLV/1XcxDSuLvCmmY6/QhTMJFJztY8wA5ywKg82mY0O0y/sQyLkwUmDL9JuSAjkBoRUw
MLAMUE2kCTyUnZIb3FcIA1zy77rihEEorDMkmTdJaEOq0RuyLJHQb4QTZ6iuDDQeuMnMV1YBzF6i
FlLigZeW1U0zGmE/l8W7Ck65BtJ94Nz0fREgV6QwX2cMBlyciHBjFZoldzugvB0boYwisoq0t7dn
p41Gy4pLRiYX8tHPh1Z+ERyPncQ0kuWOVhkzQJ0V/oPh0eTqIcQ4xR0efpAMJKyXRqfcUq4Fm3bm
t78KMmkHbIBLe6+7DlTy5nstmKS8OIRB6ELGjxR4FQc0HfxqDTYkhgItNVpEwYXOqcM2mnNuBndj
LcYdpYWGDBx+hBg4JTK+DAMPE4G6MlsHiTI7s5G4sIYwavMZNtou19sm194etZwCQtr1CSnQWlMJ
hcp+ePGE+mkum7jlLYwrDKIi9OrShY+wiGgRx5YLk8XFrdjiVwGxkeRgoE6K5A05A9W0RXWoKuHf
uOy8rj2nJge/CtuOIS/OjYMDirPi2Jg8bLs0ew0MFR1WmnHTAOG6rLSaZrPqpDQygduHxobQ8UXK
uQdIqhUMad9VOfhmeur2gw6vLYu7BiwB6Z7DKgxvnJIXG9er/5uUx8di+UPm2eXsygrAFfr/m1/1
brn6/53dT/q/j6X/e0KTneBko4UnpZkZb/8szgHTbCI2yvf5aIkmG3BRAEpANK5JBJ0kb4v83Zp5
4fimAd6o0KdgZig1gkx+vsYwqiV88uzR8OXeix8fP8RcVq0UDCn4RhmzdvGq4yhMaHTB937SYidt
bwx/ePDvQ2hqT2XFutXrbZiv+gTpvs1EDtAZRbxvnWbvJ/l04LbUpkaePHv4B0vB+II1jGQQhLrO
4uhM8B9Ye3MwV20BMoQMGIlvKxD/QzZLsuT52eKkxBmBEP2LEo1pK7wM5sniBpOjYgLWcjhl0p5B
AGX040bYTrt+sLAUHWEAKC/CrSwRrE7xdaJ18XOwopwvWZfCN8kcdl3rPYfwE2y4Aq7eSmfZSUmJ
sqWxoGUkw53LLnT/WMVvOp+OueEuGUr5beF73RAZhdW2xFQYhH8pZq6cT0MdUTUrADUmu5Kq8yHO
/r8uj47y+fdo9jVv8QLr8nNb69Tz02JhHdL7cjV2BZ94ga8CO7uXApdFC3WChg39B3pnKNQ5OPEe
/hHsINZG+s1ySiGPiaCB7/DXe6lh20dBIRwl8AL2T4ZiJBbeIh+7Ktj8bT7RhfARo4Y6+mJaQKJg
cKFybajoGqvS2tI9BBrn4Ygy/Gu/f1NshgchFThKKoqh2EgzuY507kDEAJMZPvj2h8dPh98/ePrt
kz3IDxkkDhj+QM7646ffPZP8SUAPKkXxCY4AOGqVciibgDn878FHFWJ5yTQxvR5SC3qUOjxTMbAX
Mow0tC4qbs3mJcj3MM0V5OF9l1cLnN0CQ9VWC828UGokvvYZQ0FBbPglu/+Z+0OdTc1y+mZavqON
TU63NH+lUGeY9Zdy/oIwjK/bncRj+O2NupmSgxkgZlr2VhEZV6j2PtE8bNr0Cx1t6SsedMW7fUW4
B6Dn4YcDk2Nwlf0tmrwDtR+BFgJo/BAppOWsfDELD6EISgRi3k7zUwg+QoWT1rKi8C0LMX1VW89Z
DCkW6WLfemdUOgWmS6JSSWYWsdowyk+HWVWMXCMoJnX4t2N63gpGM0g/b2XVCM457Sr5vKWYAj6p
H7xY29LQnC2QhbBogCV43xPkAHpLdVYikynU65Jt7txMjACvs/FYrlC78pUMlsLyP4R6uK7szyvv
/2/cvL3j5n/e7e1+kv8/kvxvZXhmNjIrYWEBIzXY8Vwnil7MQTCbr335n82PZ9m88iT9Vcmgq+JY
HET8AwFV7Moqw+FbsXAgiPOQv5DcJfZBdV6AFy8FD8znXMQRTmVBiv3Cn/yiypOagZWeadEKMvo6
V1Dxr90KwKFkoYAjQEcbc3ZMDwKuT4YbXTLc4FYM4wkuZZ3vZTGPx3Jhw1Rbtbg8RENsfMnFlrOx
0edrfHp4IshKIBoPaEGGOMQDx3CofGuQPHinkdTSfTA/XkIK5ef4kRgjFUQ1XrAUhNM9HgRt66kq
cNRhxnX0npBubREmDGsAceQkh1PTtRBjGg1CU6Qt0/PJbHCUvnr2wxPH9QHDMsnASP3kPNDMRdve
U2irJti1YczykPO3R+xiOtzxUHuYyFd9TUqxCwWjLsSP1E+hYqqE/ZFtiQYmHbpGNUy2vokDvXET
aayqjRcPXNUM1OzUQ8t0puyBTdSyNhRxaml7Z166fW8xB7LKqups5azqWnymrqI2bFZ1Xa5TV53M
uivkfH2TDdZVokU9HNE6FkWsdd0y+K1rJcW04plUKY2HolY851o2LTFqjFKJQYRxUpEK5nC5gILd
m2gxEHemQ113POrqmPC3G/REh3/zpGxFZ6wF0b53YPSqq7jGuFU1urULycGqWSgAr038AKxJ/V53
62PS7qApGn2wQjjkBRhDo4MJJxJUoFdvQYuO3RXdCjTpY6XdoPGmuAhBZaODGqojJgM0r1tiD/ai
D39FCgx/klMRpUPLgzUwSpMbigEa7JAGVl8jPCibWXbFkZrPfJqQ5jmLbFIs5D369x2didbM+9vh
LLT2O5WE1nxdf99msGMbG6L9odq+TY9Ud/9ve9fjqibON+gpzBnALLyrY0GlsOdCvPbpca4CpEMM
a9Z+zHPEdVrXPdkiO/1Twt8GAPBVBjr+QoCKS4AiTu/yPIDBMzRo8rUDnJzBBuA9l4EzHLiYlJT7
UggoeeZwgJKvHaAkBTYA6o8ylVQYKOXiFQIKD1kORPjOAQcpvwEsGP80Agh5iW24YJh4ieyjRgLL
yO1zaNMuzSBkmlAr3ZOz1azuxtvRQn2Y1Bfh4qt7Cm0Z2JnPDBXH0HMYwXHs6j62ARhIq6/q7A42
Iuqr6t1DcWabcGObGyqroWCiFoB1qgOGWy4XklPANSWoRsXJEzUlNiz+XiA9Kim3uQtbnQinAaPV
cJ1QoW9mGKQVEpGGSjGx6wRMenw6sCHRrpDRrO0/ujJC+345Cwgda6y2+pXmNtyUWzTgFLLJNVhd
MzYXkPiIa6BCB1TJLTuDfTY/xsQgUtXTxR+gipEL2lf3t/2cqEGpBRph7mTlP209e4nbRcfYOtpe
KtQnzx51yUYrfWhRKr7sJ5+D5YCo0XZvYXc5fYsY+TB/S/oEfebdgzc2t6GgSkSqxfF0edpJjuZw
qaBoNkl+J6bll0yc1Z8+7fV2LCCL6VHZSl+eLBdjuK7i9ui6hXSlBCu1bcyVArBLwVoJbKzRpT8t
fnr5+NGrvRc/dCxg27XlHz995RYn1RUrjgeGusqcKamQapulLRnbmnhjEO+yQoWcLQQUE9PPX7Wj
yJVnqydoE+5gWPeI1s/DIVDqcMjXbCRmvERDmL33ohOi4/9yzuGR+x+xmq/L+7uB/7f+Jv0/v/rq
xqf7n490/4MHsMU8m1aouYe7ZHUl9Mnr+x/S/xvXP+/mV78GXnH/e/vmLW/939r9FP/ho93/ggof
lB+LhHQxFOIGxB7gBSCRW1fEa1/6Rs05TQdw+aAt9fhiRsho8Civep0bUh0Pir/PsjOQB9U1bvY2
KybZYTEpFpB8BD82vI9UN2z6WmjFJVvfgKf+Si1yV1blFV6nsAn5Spd1niss6cub7gEKoo7n44Zu
7qo4pgKi3MiWy7X+RdEP0Qr23HHUVrdrOKV8t2YdMiB1/GEmGA+kmuDrpAGV5i8Pnj/+kd53f9x7
8fLxs6dOuFEj0hapjnSEMqvcbF4uSnGOoeZhqt7e2Nlx28ozOO7hPODRMhTF2Rhbt8RgSTANCSuw
hvpVrMa4qAKV9NsVPQ2PBFUHusP3wbo6dBWGrYKr/5YbGpPDdzESAwGxvJCZ0Rry0yrkkYZ+SAaS
LX89asvdtG0oon6XPEieQMjgPxaTiUwsB6Z7yK6IKSUGjmHxiDV1OusmPy2qn6DUPBfcLTdaZFfP
5N1JPsVmsO13gv/M5pBakCMji/ro+faTGP+bvBIlswWEyBBrpFh0Dd37BCYoxH6c4PPSa8eJOW9z
gkGIPXQcF5WsEiSbav4t0Fq5EXsVJhq0qMrigAcpjGnIJrTpqpnFwh6VSeW8iRZxPitGzkolTA2g
EfvLL2U12HEHDpzKW6uaVev1Ibk13yUuq3w+zhaZOHxPMrA1JRxiPHG4Ziln+XxR5FWDUznGdVeV
u0WFS1GQoa1SMTQM7mYrCBIsJlnLYDTWDupfie8rO0nfWSmyU3R1lhYD0w1JdXplSjUUUtOjErZB
FjMp4VwrpmtuTDL897JUY8wnANidj+BeQm0Yw70XL4YvXz98uPfyZXRmXyNTAycMHlVCiLNQ3E/m
owFONffT9jU8NvZNgqFwPJ9X/c+ru1az2GQUiRgwNfoVBKbOpSYgvNpwCUSWXIMltYLSAUvvsvkU
1IPeYsoWC4gimgAE+VigaLkoT4UMM4J5n5+Jfznf5GiB8TNt+PXOEWUYusjwyrxjxUDXYC02PjSM
glyWU7FJ4c/JWR2P8c0CtMLRazVtNzQLMJSWUtVPU0byISkrDWJTElx4c5Goz6qz6aj1QchdBVdd
tdFNynI2lMpKg4547WtBGtMktaw2jCx4y6Oj4j2FdHCZMzlZ/JZgxHb99fdGNsGSvLD1m8Nims3P
yESAzQhhVuCx7yahcehPEBjuEUEPWLQ1CCUBogGATIo/uhMdE9dICyi4xpAdzo7Sc+u6VwXTnVPN
ze3N9sX2udfFRepuIeZsyH1Ed9XxtgbcDsT/O+YmcEXWb688yfeJ/eA5WvBqxfFN4DzuH0W252SF
VUEFPhQdDNXIOSfEbrfneVqx8h2vP5qOAecHXCKAr0LtcQKXdjQmazANxiDj3gLkgs5UmtlG1GbY
s1iH2ZBzfPD4uu8Rkx80jHzGYExp35wovxCTkyh2lH7D6+0c8p7zh/YFrdh7GHSCClDMiaCMQm1K
hJA/uXv6D9QQdCwKAjX736hP8Zl+BEpUAhfiuwm1C6zxTRzXMP1xulwcbd1J254bujN9GG9CcUSX
IfLeanI+i+OhWZTkbGKedgIcDP0XiE6zRDacvH713dadJJvN5MwrMfcwn/AhUfMb866ZAScainBw
AljBarATQtuA7LHiAx9SudrxE69fDwNq/Dx9IKmoS/ZROTuDbRcbhvZKjuEoIyRU148I52ae/Mnq
pr/RcL/NJ/kiN+fbnGlcsnAPykBLqwLkaRRZXlKzOd5/sK3wME0/wjaoJghn/u96N3SG8l9oUxRy
8KzlkVYHBfh2PUdX7VlRVjqcy1WKrYZ3gROAxVchO8ZD2CcGnQVln5oDE3w5FexrelJU6MfGTmvW
GjcGqbLN0g8jgQNZkeFX3P4sp4hmyI4Gi5G8DqO5sFe2WwYDcPAUKJ/euumDtHOuJZyfbZOHxFmI
vMKqUzCG8KrFi5tRCvzevkwsnucENG1iqLWKFa+jvqrRtl5O42pqXY/ngl8fLSfDio1y0ljCvRXc
Omy52FAJtlIRFlGGRRViPuge312T9zbiv2EezHNnTbVY/ssJ5Ss8zE1egOr9RM1G+OxuKHpqD/do
QfQPdv8vb1I/tP3P7le9XTf+U+/WJ/ufj3X//5JiqkhOCj6r+bxKZPQGffdPhkLAdKq1bQB+FkzS
vu9H61A6Typ2rU4/nmBgRz3iDRYa7Y6Xp7OqpY4gFVzVZWAfPGilHYju1E/b4rXoePgmPyNLZthZ
K4A5q0ZFoc5rCFJ8H0GnakNDx/o3Z4sw9HC0NwTEIPqsrtfovFNXYqjivUKsFbR9FPuLjZTiiOP1
czCJc3Vdo3e9i5rgJ0epkUfb5rE88nP8e6G8qGOTZelU0mp0kp9maT8x9hwVex3/Gu8xWI+r9YCh
KVRIEYakM1kUP7WthmQgeRuJJgz2xHHHzltu82LD0sT3XRXtfkofOGgw/LQDrIToXJJcVS7nI0GM
a1Me1jPem9Exo0RVQ5V/zwSFuACKwh+XJTVntk2Ehu3k1fwHI5OaL9sfhoQ+2P7PnP5D2//1dsV/
nv3fp/wvH9n+F7Vmcu/37f5+3HEUpo02f+Ru2LTOXsmaPkPtF9zbj9JzN70ia8FspRq+TCUjRXt9
i5E6HcP2aSfqDHXugCz4HbW8bbYMd58br549f/xw+PL1d989/ncMGEl8SsZAtECBVCP83m6oY9fR
OV9UcfnKKalyv6iC/MYpJ1PAqGL0gkuh35ALKLwMQomlJxkE9VLl+JFLzEbDY4E6f/Cz0TZ+CLar
ao2z6uSwzOZjq4p+y+XJIwts0wqvI/q2Dd+CfZl1re7Mil6P0mvLGxa9D4+K68Dms6zM0vzGKfdz
eWgWgkenhMpybZbTLzsbF7wYVNe4XqS33LCQlyuTPDsKRxRlvRtIBqfLyaLYUu6lhp6d1UV0ofLT
TxKSb4rxvZ9+Umo3tZrl93MNh1jLAIOzkj/Z5P/1z/8yqur1+ACt8v/Z9eM/3/50/v949v+8uKV1
dJKNs9nCVAHUuQB080l+XJbD0WhXigB7+Obhw90H1NDGxnCYTSbgaJfsp+7X9ODTkv+bXf96cq/A
AWrX/87Ozs0bTvzH3d7O7s6n9f+R1v8LyP4oTvZnyd6TvUfPniUPhaSZLedF8jCbH4qdfldyhK6Q
dwUrEGuXc0JWScbpIPEQcaO7091JHjx/3DXYRTXLszdsJg9WkfMiFxg/21DsBrsu6ZrvRVbNDvP5
/Cx5XqC1/TyXt6GVcS1Flg1cRxDsxuG8hPhk8tyy9/L5jV22Lay6G+tFp4e20fUn19Hp5SupwjzM
qvz2TfVUTFGRGFJ2No5wmY+ErKQ6ECLRcrRYO2fmq/94vjd8+P3ewz88fvoI4yxTKXEoEP2SfbIK
4vjq1XP2iX/94gn+sgqjV74sLN6RAsIqwr7eOghm+f6Mg9R2khf0sZMcLovJeFjOILyOHMCvovpl
fb54w/o2h6g8MhSmCpxl+IJxxHfHI8xWpFhFSeUhC9oCNLqMW/gledmsXxcls4nP2bcvHv+IcblT
zXjTDbS6eP1y78XTBz/s6Y/pxoPnz4fPBSDDx09f7b348cET8fFGr9vbgOjAL/b+7fXey1fmt13x
6fnrF4/2hv/57One8D+GP/wAb2/dgfeimZePHz198Or1C+jkMP3T+ztfi7d/mv9p+qf3O9mfpunG
y+d7e98Of3j27d4QYMHzbg+OTcUET6fJjng4zCaQ0F4cm5Jd+Aa4EL9viN+T5bgYzUtx7LlQ/nU8
caQyNG8E2+o88jITQiiu+5krq8CCV67LSN4km9iNP1SG4dSN2afuBnib7AD5GauCpeIP1uBZqHmm
9Fd03Rlp/QHyTcEcZYSEZFyMud1RXrwFg6bTbDFCg6V5LkY0Rf02rnXu9V8UI2pVk3Ihw7JwoP/n
+RR4BENDHeNVQd/1DeSjWYWxR50kqn40SA5+4emLZchWtGZAi7A+K2yjeXb4OIiF0cCoKqZiAxbk
Qg2QSUibdPvn8iQ7nIrTrVgofh+k4j4SC1mqupXq2m+aUo9BegXQZ3ufIZ57h9pq+3kWFDbMIUj4
YL6PawBsAli8x2AdSLnlVSGgonVobLiv4huwqZCg+42B/hqLteMtgvZAV6RpHXDjdKq37Mlkr+Pi
uIhZ1TndmshgbAO68mwawDbGw7skui3cMYFOk1ZPMDW/MDSxAspJdib2DghCPIeUaT6wi+Vsku9r
AukYxHKgwA/TKmptIAHKdipvZ6iDEBF1NClN8iNB4/Pi+GSh52k2EZMhWoKRmqNRtAG1IMeBfMb6
8vIqfy8Y8GgBmqthMRbMBZSuYd5iDFszE3PYARRodRS56kD6mpxsBVkpmiCmO0jW2VScVoU8N9nC
l8kJtIc79E6vt6u0UsjlWScHkYiQgxHMlHnMLJC2ZYAZ6ng4z96h4ZguQpVkgdQuD/adZlWbJs1P
PK8wEKuGbYcmM/vSCAd6WnyIrKLKgVbS5FCuV3PkWPQ5l0g7gWHaJRg5qk3usqPf4HwAnM6KsMFQ
TMYeHl/2GlGfnNG7HVtaR5dUhkwqNmwOIeM7KlnVEbLL2vkohQcQyiICpkjvsnkuFtq8yMRRhAEj
rQqIA6f54qQcC+K8eVsRJxxi3uRo9sfIhgvXVwDVEwQKHg0g0wAH1ktVT61os+1zY/NWU+8Myb1B
0guyZ80mAzxPfCwwBupsetwCWcW0Ywef8FnxXhCzThipeCCufL3kf+SGEiGA8llInNq2H754yKdC
2ioERsdCOppWaAgqLd3HuRDwQYqi3hRimZsCXKbZoiX5tt37bEs8TZWeXaItAwilF1x5dFTlmPgj
nzrNcuKTMQZCP8mZAffoGj97NyxOxnMZyVW/zCE1r/FydLKcvhFzO87fY21q9USQuez7y2RnN/mG
IEA3y76R7GR6jN0TPrvL6SwbvWml9x4LgoKy+9xGXzd286C93zvQiw/7h2j4kPDMqCJKmtXu6CpQ
imwpRBVdwP5O4zSKfsnQ6p7nI7MU/BR9mtQsS9wLjX31fAKhiTkVqJmOMsOzkcwVyXFyKPqow58E
rc+w2MgTvGWZTbgNOP92xc8buy2N1PbKsrobxFNf9njQMaq0ky+S3vvv+D8TR0aznw2sYa2LqpMM
YpqKRYtLPhEL00QYTIdJqh4zUQWQlj6D4+bj7799kYJMw3QqXu7ciMV/XQXatEwIMGzVNj7FVdjR
i9CbTns+iSD7NnXeOfAij9LiFkuvB4Pg1uUjffy9fH3PZIZrDtFgeGBGm9OGoyImjilTlTNmg8VY
OYDziT0TAzUT6xIEJIVBj2q8MRRcHVFPbVsheBWT5EXiMBeimC/F5G+EiYVA3Hv6beqRlKac3mUJ
x6Bp7COARmJDXirlQ3HCfrNhbjQK6XzkVLXFM2PhsyCnXg2q2hKBZzHAqSW8W1TO+zNujLm+QSbj
MutkYtmXAZGSpnOI27hh2oj0Oz0Ov9ebPJuU0TbPooC/23+LcLEwtCWEoVuJQe+g6oVNP4cUgKNc
nL2WgkbGiAcWOCA0kLPLx89M8NU9LK3a6k+LqoJ82EzHpEIcB4+6hbRqHVsZHFEaMkW1EyErUix/
NliFg+n4DNOaU/UZOMrD2MCQte17qnE9YjfQmMzbiSnjsMPiNDvOt8VE3aV5XGtZI+Zfv3giZR1A
ODdjuFIpVAD0hJ7fJaBKU9Iv6e0nZ5hcskKzArAd7CavxDl+DlKeEGEWZGrD0gwYGoC3IjeHHkCY
gG9Rin7EGoc3rDejsDzG5cA8nwmxFy4xkDA2NHdoSdRKP1ZU20NMVxh7NUiLY9GOOMC1mUVb1N+Q
XKgOM+eqjjtr3KVp9+ey0PDRmbzdDsD+4UHzI64KAoIJxtrdw9s3iZFIiDpyGeaGB6GMuyvvRroN
wu/WA692GMmgJS3SAV+0ZGJLgCwxpfnUGhy2wfS5goR9/BH/N888A/3TzucExULMGs/cOV4N1J1C
ld3OaQaq4zyozuBvjkLjtHwbLn6M2wR8lkW1qkQeLLlJqmC3Wy0Ph6sqqCKw1gQD61lahGi9maN2
AL43BJ4pVcQANBU9U/oOtmNeVjUKvbQYT/LUKS5EjV3bJU2PDJravdPb6STi392wKjM9KU9h16hr
4mts4utoE5h3sqYRgPFWbydceZYtq1UA3OrtdqCJW+14G+I4VNP9zVj3QFOnK2G/Ea4MTlezlZVv
1lSuh7r31VfhuqPydAYO5nZt2y+P6c7QnVifUYMHyvYWFWyDPsW5efMqKIWY8nAo53pFfAMaTL3t
RibrqJhkkM5uCFIHXiXVzT1IWmI19L6+Lf692YPfX/dux+hgnovBLKwmrcTZ6ou93m50kpvtfnwi
dnZu3F4xGA7wTtNSO6CdmzfFIHZu3lqFn+UUGg0OJoZDiy/c8jmIvVKt0rf90ihx2Gm7OfmwNGYe
HmXT1lycGcTfyuX9HVARautN32PC1EySwlqySOb33LBWDTJnnuWg/NDOCqCxdpWw7g2VVDsSzYsq
7cgNo+HPkYpikBE7e6e8LXrdHpyYqbVvYH3f6vbMXqG5/XQ2WpCPBBwESLoXR2uxPET1bapkbbFU
T2IV4oKB1Cm289Yh+m57qP09nE9GkyWclbK5QIvKtITyzWqEk57FwDl2RAg2+pdopk4ixfFbSk5Q
NlTOvYDS7yj+AVyFi66cwtq5uvA78D1h5PRIJRPOET3I6hqYeHUqw9XpITqZSuhnJhARlHBGPfvn
Ove78ByrA+tT2a8+s/Z2k0U+yU9z8tgX5xTbanJcCJk+O6PkuQIr6ry6qAJRfht7vH140Q+uRQTN
zYPF5UdZ+BBPM3452DkE7g81axmdZEDqwdK/GmtkKA5yVak6AJbFF3B+PfhogJ3Pp7QIQ2Djx+E4
pxTvnOM9Av1Eg70QfGAIm3qwoPqqZE9kp0ObAWsZ1WK2VPQU8M/llQhsV8Ay6uKtrFBHULty4Uop
e1/QJpm+hwukM/jn1+DdkQsm1Fxxc+QEZWCY9qHmgdSS8LlST221EmaxL3WMu3jVSSudlr/+OgFP
RIufS3I0A1O10kO0RbIZvzhHW2WYHN1y/NrdD9hjmFuwpZsVuDHHvy/G56DH3euDaCEgOuzq6KIG
qGMCsyvaSq1BZsv3xaSAiGDiq3gYeiU0GtLDMvRdpf6GIvrJL0krHkrx2jdKhIgOhB25uOXI1qE5
qLtPiHFQqjVDV/QsJes844veUsRX/eD6mC6qgDeqf7w3vZdBOpMl7TAyLkPvrzqS27E8zJN3v8nh
3KluhAxtUH9oFvfaIhUR3GSIpqwW1BcFh2M1saJ0B9M5shnZ/oHu98KcG2MlwiwZj0Yp3FP6SF7G
29MS+vMnh/nz6RDq4J4N5wC1B1gbOYmvJDKrIm0hwd4Wgqw4knszp3l/P3EtMRET9g4Srz8k0dt+
4ZSWPFwMBoibn8KY1Ccm2qs9tHAeVqAYabwlWbUynaEWxuKEN1oMqYJPMvR5jZZwew1DPQFl2xBn
UbUlgIwuH9DmQFzG90QucqtnAUd/c2m1piRfSig53uhMiig+MkfgD5k5GMCybPRD3z3cLavDeKUl
xDx+41eCKzdRyy6ML91hhorEx3dhOtqzaK8ZtSfe/1wetmqMVq1bK1fQZ7lNG/WY8j5/lapf6ds5
yc3IufWBOhqfFVCVzDZrYkAJ6ubQMC2ZTZZVMhJMLUdjoFvbYBEEh4sMrVWu8axwKdO39Q8YUdMr
mogTCvBYYzuoFBDmzPnHWOvrwGidL+om2awiqT5uJUdvxpzrT46AIoQXePNRU1kVGwKiBQccuSZx
jZXZYraHOMPiny+N/jFkhHpwzLX0l3tJz9AIbAQD0X0MCYdDqve1AaQB89qSkDKq1O2ZvWfVGwM4
a2aWS7gTd7hUrFgNJ1bGgqB36qtpNUrYZpZ9h+QNaA1ixS1EP5qcn2gWSakvKdiUDRXFUQn1bLaB
pATV8YcJg8/qUuJ1yhSV9EZ+ORUcZYP581G+GJ2AjwqkRy2ySQvirbN2JcOYJyj56diuHBCuzxb7
gwRUda73+bcQkw3ysi7Y14wap1s+uEB+8uAp+auBBxN6VBAnhfLUbYKB8iXX/GWZz+GOSPkwtc7T
f996Vb7JYe83AL2QK5/8MwbShUmfro7Sk8Vi1t/ePoehXmxzWAgIf3f/HPu5MOL+0a18NThPH4xA
RAWPfcOFfhv8xOCE9FqMcOvBMcd8UDqj7V73dmpILKRrGqSP9l5xJwQveVbBBa3haNUynbFa5xft
QCJNjGZJxbvwpzWXLlsych//xata6ZNi5DF4eWOnl2yp7DcwM8qDJp+OZ2UxXUTCNcrWuuCY0rLu
jJVjmndBDLYV70ddtBYZDBL/4sm81nWdfiQzE13/zBk0wOEnq6p35Xy8bVBO0kLKEs233dvllb2o
SAdEnWJhLQRxZzMOftun1+dyGBduB/LeXLrkdRJ2K+InzmO74vLchcqR7RlCmC5YPoI/L6diHsTp
Xyzzu4lYfMURuX0/fr4NlG6whYymGY4NUFGK9vpmSo/Hpzg0KRlQ4DZ0ytNxjMzB4/f/9vLZU7IM
kl6K0wKerHevhJx5GYQoHJhLWJtnSxMDgMGdIWZHUhaif9GCi48OFIQGGkzVrYoMQOlbJ1FztnkS
vZNmRVcaknYyIycKCT4p+RgqNSS7Y6X1n561RicUh5ZYsYCTXqTbv/syRbipULeo0I6n1TYKUa21
x6FmwwFaEGuVHeXYgRGT0LZ/oxrKU09FHTDz+IFrIVgmJZBF5GReTstlJbn/tnLBY6dOa0synJ7J
9Zgc9CLJAUnL3A87rgY3SplEWW2Y0mA+kFCQWgfLaPxhfzRax9sY9WQXc/rTV3n2ezdHICGZFcYh
D0G7OCYJ1+lSctu43Qm9KsQ6jIy+M3z+cHjO7tHduWBCGHKm9XVv2Ovh/9tg9a6eLtLw0Aoj6LOK
ty57uhiKYn7Geao5KpdIj9JeX5eYkcclH0fRsNHxwgzlRJTVGiZirETphkUx3JwEGwUs8AZ2mhOr
ZXW2yDUSS87zY0gfOm+UhBIhlNl7oo6lwVFBL3REi1f8qyaftEnqY6SehHRU6CU2e4fBsS1PcYu1
XGPqykunoLxC2stTMY7sODcr8aurJrskprlOsku/xnUluzzS2S67vAl2z7k7waNSN/vrUEmXQ1p3
1gJ8hb/scfP1lVsbeLI9XKCqgZJltwwotlQ1J8L5OMtPV9HtcIaakksAOyOGuQacaDzWCET8+S+c
su1Mx6c3dzcdqF5znX44W4pVzxAKgDEXeKONh2WzQT/wvd2Kr/hqLkax7ERuMRAlPZ9SDre3yLPP
ctNZZNVAfCwpEQFjJoYHpaLAUeSK7XO9wRoIweCO9ra8DXyZe0jjEJCk9kFBoC5qYKBN8HpgoC6p
xdVdfojxe1LTxbbXX9ow91+YV3Vlyrwog1AlGmWM0NKNk+GUPsCuJAWvlpEjN5Gmom1/CXryan91
JoSV2QVIOz4Fh4j62mbqAQ80D5tFNcRshW5UhUhx9DaQWp4dMz+D6sKcifrWzZJ+w5oB2htObCIx
QSdtqOocYhx0Qlu1hp7cR1QmJ6KHcOqQyPTxSdjTbXpFnQNYINlk7CQWLiWRJkbVEiJFK3Qw60AM
nzbY7MIfr5l2mKCcvUQe8yOFfRHdFct1zuznQl4RIL1P7IScbe0yQR4UmXnCNtO0Gv5/ulUxp8Uh
egZNzphx0fbXTR4aC5fCam9zMlTYIuc5BxuHgLTzQMuCSMvlMeTjlSPcdiXacjqiq7ppvnhXzt8k
QKvY+HIKWvZu7aK18eCRh0UwmH80UXlGBzd6/vwhE6BbESdfjJV2NJD7x6zZLH9XQ/0maj0s5JBX
rFRwzkeDc6PzizRGlSF1gOdWGc+HrNSZMoDl53g1YKhcMWBTkkF62YT1bIPPq3baWbmWi3HnSusd
VXoNlqeTqdvQgZq+SZ5qs8GCFRhoiTrtaDqhmvzhgaN9tJyVpSc6E5I2dJ5fjegkCKaWg4GDQ2qh
lrExtCOU66PT31GAvwZr12418ozXDk85MGyzm98DoxZ8OsKmP3puenGQyhYLiAdiNJLqVNJiWsim
MbS/RwnsKknqmxBYKJF9g/2pVm0ULFwDh6EbDwnMjv16JxFSyVinta+Wh9VoLnazlil5Q9WL7d9x
Csaek+p7DZa9aqRHqQIA+bJkyetOVmgidI2QvK1ThhJmW4H09ia/iCS3D7CL1ZvqXyMb/WoyitJu
Gs1bn/4tp6VvNmLr3HXkZ5DvJ+cGhBchP/cVcnxsBwp0FaQni4lZ+GYVYxTZ/L2vV+oP9KYBcr3T
h381ys13rSvSq16T9uvWtX87KalqtAjXNKtKeCmXyGBgU4ijpvCCd6ChG9nzomtcG1pIyzdprdiz
mr/HyNVmWrW8iYJ26o5IsPRIyclxKHbT9UFPnX7IUiG9lHjmThGFZXhXTMajbD5OeGeYEd+ZVKVo
VBzXSkgQomIniwPXfJ7DcQrjNBttyemsEpWvliIyi6MS1d7UNiN0RduNU8tnilriROITq6YZso0B
c69p0rrd6wnZS/x7B2+mdSk2XAXCev7s6aO0tn2tAuOoU9RGMfZ5lLFgdC03RmewCz7Y6ebp1You
SNIIrkpu0LhzNHLWmhePjssOfVFiDj8jTHpIXtAjWS3qlmG03VXAsQ9frBzGrOX1qfmxJ1BE1Efa
xMjJmHWeKqUuGL/bl3Ww8OQo5VdfB9pukm7b5nqUpNVLykqCn8q8zRkIL516e7UcKAGSqxXFQe7k
wpQz1EVLDMFBFRse0Lx41G2Py0O1ViSzLxoYuYxNfgyc+MD9qJg6+oLfJS9RvAaDa4CFyB84ONz1
VklFjpk6OE3+Fk1NMJRMlWROY0o7kxSnp/m4IJ1UNv45G8HVMrt5SovBw+W8WnSdaGNq9amLfH8o
8mwaDNy9lZC992kpsFeK3V2gait84x88R1PjYB6sEGxM2iXO0+tkL/ZNTMJZi83MxZvn7HeQwgym
F5vh4rSEYoCrZdVcTeqbT7h4d8l5vVUqBYxxfrg8Xq3MMrMtISnLpWto2j6vrqDNYujrFRSY1RkF
HpaDbSPeAIMYi8ITchfw6PZLWd3YA7WdPWhR0PlJNbHlNRE+IGhuwqoibtQh7DHQhT7MB45jEFTZ
PIsC8lXw97T59Sv11L7mYRqMce1xBjYGGKy8JvaE3KuMWpOPdf4jAtLWO6HdpYm0ApZ/SvSYOiIL
un5WrXZcEJG7Iv5dTwxh7sAjIamTIt0lEI7tNOi8WxdaQMfGZ4vE57zIoQac7bZePH+4VS3OJmR5
KLcaYOVAAirnSYWeFmNl9a7Z2v9t71u32riyhPt3PUWlTGIpQUKSwXFwlGli45hpDAyXOGnCaAmp
BLUsVEqVBCZE35qH+J7he7B5km/vfe6XKknYcXe60fIyUtW5n3327eyLdYLrhUZ9bAbEPRJzx34a
HkXsWRAsTt7+GNKmk7XNRZTHpWSu1I6i9K642FrQCGHpyBPeOgUcuWVSWCHAbDuWdtUivqP4HDkm
iadqkGi5yJ8GZqBLPUqhxl0T46yLP0Io2+TnZBWDSSH4oBcNfZlZmzqXqdZZCMku4IDmMNSflsYv
vPbO+tfHwHfra0gYI1jyhk7gCA+/oFh+M1wvInsT8dGp8eKLzY8AaAtM9FG4xTGeRpR63RG6mySZ
iBRJtJqRwVzpj+tWS4dxTQpAXAIYxe8nEptis3jZg7KACCPe5abdobwFqi99gSEQkSvsFK5Psd7c
2Xkr78yAH7jwjv2dEWj3Q3in7/ZCG7bMZik9AKOsSxipGfWqrl7EUh0AqdMUG1RJmLb7It5HqkRk
MlRaVZ4+o8LyTzTmBw13l1k6Kqhm23fq+8y1r5NRjCzvBJ4TUbon7I+4C5yI9MFUQCIeCdKHHgbg
kNYUWsQhgqSeCo57L+8EZsexaabXWiVE2GEoejOMjERX0b38FHiGrzbv0HyJvXErbt7pvWza72V3
mk1Hi1qc3sceVqyh5Z9Sag/PHGw7wl1zAb8L7ke+RJUif/mC0q6zqN+1Qys5Rr8JCsu6YNNLuEBw
06D5A9dTNjM/5EKvAhY8TlpYFuZP1mO7mhmY7YsnbKC6oA2l6ccjuMcueQlnsWm1oJWlHffDHDRj
AV0lKFAgmHBdaMhm8Qlt7WA7dmxzDkSBcehHtQuVQoLI2lekw7YG5jfIXMhQ0mcjqVmd+NcKlSYt
3ULTZBSMZPdROhigQiES15rtiNOHNOsI6WU1pEDqPFgzsy5G2E96jKDpFusKwjB35SalrHTh3bnM
FGGdsBJ5+HYmwG6xgNFwdNvRdDKoPYuqTpIwfrXJvVy9hk9ektyjPJ6kr9B9wClmQHiHw5j5XHk5
52uFgy/spaBl8oO9Gk9uXUKvxaEybjGMXWP4RKEf7gKI++dBR3z7ZExKJuq4gM/nxoLmK82vi/Lo
qpY6L7ur4tLWvBhahVEmyiNNuNEmyhSYMnYE/bVD1qB8aQdJ0SLPuGdXpxklUe3YApxGenGKUum2
sgiS0fZE4BbDndLfOSujdeura9oTERz5W2MvWTRV+uoMnDkjSaEEheu4XxFMAlLDSIcojKRhaQaE
+YIXI/qgke2q59Dko+44v0yF9q0kKroVJEZGx3Gj5yisKkLiFAQV1SOItm1SLntoW+F28IOxftq+
YEaW6ZjlMFjUmcmranxa22XdrMIum9YuZOCsqu4EC2n4AiCjArVZwMJeVJdvERbV0xw8rWp8gsF9
KoZB50INXSzPPKgHbhIx/ln+ER6ySehgt/pXmIkxiW8MNawmcZvsrDdItYdR1s4CaRm0FC6lXM8i
fPmCg/OMystS8zzIOEj/RskmIn1npErOnNlqaIgsJclknO3DBN7ZpBD7FvMuprV9R7qUWqFgxIeC
qDtP7zAEfda9iDt0a4xxXShmAMXlhCl1rJhGM7MJnyFPQfoed+jc1kWtszs8O4GIwaurTbaL+RuS
+TVKWpFlCppgOTJK6lOBokVa1Ga+yFRQpf6YjrQIcItZqxt5EF141rNJFoG0nUryE8Pv0+Xhd1Hw
/eCdoeShPL7bB26O9awk36eOmOJRlvQuO6P4hgi3Zwv1oHa6ysFz0+cjMq/Q0wzNS6YTQtDILgiN
zSqSlZEekMfKght2LwDHGtRmYcCRQG9fRykMI7qpzg+4p2L1sV8ao0s3h1YX+qKrXjT7wh/ZnGl+
eN8JwlucXwo2TRoWnsdAfDFFz9VVMsEcFCpqomH4SN5hKK7k0BTZM6o4iyrb+gBe9pPBIJZBGrlr
Ur1E1mUDLThvGN5xNbybfbwjocMH61wYiSznZeM7GmwuHRW9UeXz5a/mx29kBc3YzWazeJUmT1Cw
mKeXvQK9y+7oAliv/jTTN535bYaVzzM8fJ9n1ech5fTCMrCVw1iW9NjNzLOZcQMQFq3bfGLOahh3
cOWRLj2Hz9mSEiWuPKvsp9GvndTWI/s6WapIE8vrea+8vDx7B9OBZbeFHOEq6wnvcpuFV2R+rtbr
Obggc1vO5I5HFx/gkqglMCNhYZO8ET/vv/8cDuXnfSZ8fIhPYjFUshXATfO+YhvpfydSqJUZz3kg
mSjmJQUdFNLzXFm9yBbGRUL3iyHLgVJHPv57FGOq6bDf0TK4e2v49BlmCS33u6ewcy/j810oOcqX
dnhFQYFMEbEazPVw0DAqwCfHnR4ioq+K4oJ8dhaOzsbeEko965mckbzGy09sLrU+XhhQqjd3DwqJ
E6O1sTLfsVhDtTCqe8ccQDZSajIvShVTYnw5lwpDIa9FsNM8qoD9k54PsV4Ad4QR0aVTyu8nw9i2
lymt0VU3e8dtNm4AXhFYkWGi1QfWLDwZU654xR4XNCcWh7Z/GE+UHQjnKnu3cHY4C0GpSm9GRU1J
dt1lNxfBCs4OLLnoXhenwuNgQExJtXLMMX9PLesGJQxPR4UXmwtKK8tdehHXTvGfjLuuDwoxcp8Y
I7rtLtOMmXbKeqCUBR0cVKyEUsM1b3STctWAK6oU1DMJvI3Yi+/jy9TvS1KPhcBiRFBRnRMPYMkI
M8vGaCgS4+6hzFj6HIggEIVxYbyxFRaIn7BgqISysAjVYnC3/ChFCH+fpTA7DEHZ1Ji1fWs1dG/a
x+lwSIZj2XV3iO3xzmBwf/n3+FxOz9fyrLc2RrOxftx718EnUyKo9fHtR+mjAZ+n6+v0Fz7W3yet
xtcb4hl73tzYWG/9JWx8igWYIgiF4V+yNJ2UlZv3/k/6iaLoh2Tyenoesj2XkQFv6VJLWRPmjNtB
zqmPiU7TMWbZIaFhBCwcszAk+4pOZzClzH0d4JIwHENIthmkosp5GWW0mNe75z1REIOuYjcB/40O
7uI7D5cpfqY5awkNMIbJuWgB7VNEkUy2w6MHi5/ShEw+AMzCmpvcjsmphD0HgVQUmWZD6IYZqlrP
xt0sj61nnKYGQQD4H3CXG+yzQ1dAnQ4wFi+3X22d7B53DrcP9o92jvcPf0ZP8Dfp8CL9cQr/rclt
iGTZl9s/dr4/3Np78RrLwpaoV8c7b7b3T45ZeoXgzdZP0PDu9tbRdmdv/3j7CJ4/g2MW7OwdHW/t
7nbebB9vvdw63uocbB1jY7iElWjtuputwUwUZlgj61PM9rbGRZE6JTCoBicHUH/7sHO4v39c0kCN
gVgma0h/EN6z0c5aGCWj8/R9hN/4crIORW0Y/vHJUVFlfsWsvvLKR9tvfsRi22TzUMe0wsDOVbLo
v6//o9L4/bRZ++bsl/6X1V/qxb9WYAov9t+82Tn2tXPaqH3TrQ3O7tYbMywZHMbAV+cxKfop/pqA
81Om96D/iDqdrVrqkLPg+6w76l2W1y1tgOXqICAFFvUKzjbLmWvfqIqrVHafKk2QD7AihmBnCOCn
+s/1v6Mh9jX7xoMmyxuIqy4KT+1QLnN9MB0O6SnrVph8GfHw6b0dH/5HLC5Mr05G+XTMo7vxofCu
N8M7avizbGaGgKdpVZDjhMlPWEB6/Ibm3tRh/SJLp+MccyhhbLjbMawJaYvjU9ZEjRoWS9i5SEA0
Ou8gHFXgnPPLH4wH0ulekBmvTCxrOUj6dFwqzYiJM+pO1hF470kqYlo9+TOMXI/6dTbqr1iyEbOS
kXhEzcMq9VONkYja1jip8WDY2FGr0WrVms1a61nkJPYqyjZiTRV+LpF4pCCViBYyxcoqUmdX5hVh
bmhkmdAxer045wiDxcPpCIckoJHTzMVyeRgdibweS/VjyArUH2Pwi7OHeGLA+KLFVBcZhhiFyscw
MhJkyA2yR+OGrpDhD6zYFUv2ypsxjzt/aOQmwos+8vciBFzB+JB5Mkmz2w88u6ZtEOtFoCU+bo70
3SRuCnANhGLlGMo31zAMMD+9SF7WaPRrd2oSGJOXOsnX2BC0c+g7zYbxtcS/fDzMaqSfdQfowpHk
dKESEsrU3o+zmPepCi20jXyNeGWh4mFLNn8fz4kIUhZFdxPZy4+6o+w6mRu4CtsvCkZKV8O9GO9t
8K5YY4XZMOQ2M0u0vkLvRIHrv07TSVxhZYFwdwdxOzLn/+FQwUYPD/kYZsvBBVt43IMOZ/mkClKz
AoeJeTnI8hXu9kPJRgrhQR2R8E2S58Z17lXcHeXhML7o9m7FAeMNqKyIOpXxkoV5ZugGXXgFbNxe
OnmF6Vm3TX82kU8v4iNHKshBeGbgX26/7g/GtRgiNvRGJ5Q5AMONZOYSyoX6POdaJJyrpTsqGTbz
0mXqZRZ3a1OGDp0ti8SX60Y+EcgAEDw7cHwxBXi0TRQkWpcITJTjnnx3WqcoF2Hf3dG0O4xm9x/r
VGM/bbCNZsXoi04Rk3vkYeJ6U50J7BjnyiMdsbPJsyr7CmvCkJOStAjLjbPkGoAdzSi4aMZMr6UL
7AWgqYlIrQcIJ7zJkolMsgfQmEzkKWRj2/QbPOk3FvOPqzbNj3FqVR9yDJ/onOqrOs3VGdUmaB1V
NdY76eTAA+IRXFLMNHx2YjYtUrj1NWRkZb4sOLXC6N44Y6xr082JytH54pGwcUSk2Qfpvs8SzlPQ
ylUx4tmmfXPBLOwpY5qMahhoHUxz10NCy9XJh0UB3MQg3CQcVMGTfE6dNa/koA7ixyEVdmcfAfjK
mtdRGXMTMkOa4TMfXFgtFWJ1vwNOBJWnuOdWjmo5FKt5C4U72eW1AXtraiUKKmNy7cmc6qyM4RQU
OBBE3uZqokmfDhZD6zRrgdcN01o+NS319OIovgxt/xf2SEFhGJlaA9Im+ACpShB+CKisrqU3KDWx
XIASFUl0PZ9uzkr0MdE+5l/l/BiGWITBCFUwBVM4l2waukegUPg2Pmf+EZGRZbXTTzLSoGnHDzhl
4ePNuQ+tMN60wp/KHOnxwKVtpE4U+EWOTvERxhji90k+yd1e8Mhv0zve0dZIqM7FLkAP3SGLPc9P
RzUIPBFgWEa7CeahBcnmfaX5tGoJiPMSN3dJhU7QyaYT6VmJ5Rnk34wcwp6DlvTdEuI0+f3pGD7B
iMW0aNo+4q6ugdAiNT13qpdZfXI1ZlA4wFmmOcs+K9tZxUf7nbeH+3u7PwMHQb9eHG5vHYsf2z+9
2F0NG+nT9UZhXtu8PuhTuwOMPHMTcecgHZkjMWeX2SalIuTbn16NFdVkxYB0Aw/YeRff5pZJAanm
qEydmKRK9Mso8r4eDKf5pXVbj4OljBGiDFp6pPr9uHOfD1WGyeidvmo6ADv2xhbglrjW3g/ETdWP
k+HGGb8cd306ool4R1xAXdkx4X6WDuPNgmowDunFZdx7p0XU+Fscj0FwZ1dANcojKowMwnTAImnF
QxaEXN1+8enzg1QQTsOwVVFHSRgvSnW1pAz4+XJVo7SGYgNOhnsx5AjtKpe2df1j5I1m0sx84V0f
DClqOgN28bAZOpcYPg2bqs81NrK6fY3h6HW49qHAlc1aRAwUYj6xw5KLpSScJH6YhVSyUzsmIbPX
0ZcN7R70306qUGO1qFPjiZ0My1gdTN1tPLBjWtiRLw69oS96COosZBhz8XMggC4ifWodY2528kIp
hqNiQOpqDEZuVUrPtusmm5i3MnvFsge715pVFTxJDIBfdDJ/EsM6TFLzDtfcqe3iA6XHkTU4T7WK
FZHMLADCwk3sCfKk8dN2FZ7ZGUUZeWWo3YkV9eAGEzdn7MThz9PhNbSSAUayJ6+/jKrWeMuK8rG7
vZsHRMRTNJuylCjl/dqFnZ6deB4ULMFSNrQLxRTi3h2I+qwtdUOsK/GrUJzRq1uFODhv6nBvt2Pi
LGTNzCdWeRs4ROMOjJnVOE6WdUgc9BZRA/GUmXQvhJuq561AcMBMxxhxIbIXTYaFZxykpwlCWCXv
pULShTZHdKMwMHp8gFLfAs0vpNAPm7QUGrTpfuRZQjYcyoM8TYeGU98RpcTqgqgxqp1jFxSqC+f7
PGQwJnBLjrw12iWnxDGFfWbz3J1O0hradb8rciV3B+5DmBygNwstAGFmp/yc4AESFcrLs505KzJE
5itoOpqb4TA4rdpcvK5D5ByPn6IpiTpRsOyEnEBhemwwaraTUjw2igoW2aYuNSoC1FGLBVZ1Yhvx
GdN0NEd/ap1RVZGBRJ6XooTwSnT08iUVXwBDwRyZh28QSe639np6LtKimujKDnmms1W+8BACo9jq
RolpytIeiEKMNPgEl4L7Y3bjyPLfsvgNoadDjhHJaITGp9nLiOJVh6n3FvctldOR4mRF67AXV+l1
zHINVKJrbXCEZO1Vw7inpStGtXzLJZrTEAtmDARZmd5Uw+9Cx2zM3wL9Pd10Sp+FX4UgAf/v//w/
1YVOEOy5GMSibE56Qd/UrE5MroWruiNpTUEsgbHz31lby9iC6bgzSTt4pBdExRpyqTNc4HoK0tu2
J4SRCyVt86dbXMBQW56SohYZV9B2ya0u9dG2thn8uAGytSVuG/vhmnRLjNVWX91ihH09Q/LlDLOO
NTWL9/WwWZOYO1eiP2Wo4wuTfHPcCrLEwohVd+Swua/5qGhHqkJJUcpkDbqyeTdKb3Q9kRKXNOHJ
Kx8V4nxTlFwC5ftY1j+EDBiQ6Fw9XXZLEYBRmYsJsEBYyidfGcWlcLUw9eA74DNC4sM/er0VFU/N
272LkDT8omEk0Uq7QFpluEkhs0+LmjgiMfdjHh7zox2JvRbBSlE0ByX5G/n4qMgUVjjAsJsQByfB
P/SpFchp7rnzbvjpZrN1ZpYzVt/z3tpCDQkq7rXINQ+Nf+NskGZXdO80TNN307G8Y5IZnpVBBOo4
psoXkwUgllKZIceoLShzCnOUxktJOKWnoOQ0MOCXqoACyNEgZaG8vkXarCLJTNEo1eniGeYM6cHX
ANexb9MfCh49LwQJB3B0XRPacARzN+iIUI+4Dmxzd2QR3KTwkzCM8EcwWIDdWRhBLYCkFkNUCyKr
JRCWQlrCbqssZoNzL7PEtjj65b88fP4V/P8Q/nP6v/NxHf8W8v9rfr3eaFr+f+tPnjx58P/7FJ9F
PPZ0Z7x5PneImGWNMYa2mXCXP8PDlCN30QJD8saFLUNi3tsq7ZXXsnKVW1EojQx74jPaWQ3Q3hml
KuDjkRNvRuGX4Xoj2Nt+29Eet/hjZv5DN/w+o+jV8MsvWf4pi5/it2/zDDqUaIYada8HoNfCgxm6
Bu5dhP3CuN9xX8srAz517ZW6Koga9af1Bjp+NyLdDoRuczjV5ovAd2JyyYwimE2dtK7IKb1w1WOY
wdd5wqwZ1EZ2uuTmlHPORlDtvGItN48qYWjlYNgb9QazHqw0VsMNzPZRXPq62ao/qa/z8s3Wavhk
NVw3RnbFrNVVgA54050OYXggzHHea8KtHLTQ6WqYc+9lRW30YuS9CadLbeCqmXaBbbo2aL5yjKXA
IK14AnMVSks6y5SOXLpmUMaVJb1qnOgf+nV9oeerVUd1wvL5GmoKttV2FXnhzzxjyy0ctduv6Brb
a9oXXKR/hbeUIrk3SQZ5mDEdwpyrMPSce1prfFNrPTtutjYbDfj3d7sO88TZDD05LHUvHKcAvw/j
+4umhjpaVew0Pw4FZiLtQsgrNBFp87+6exEfhXZVwrUfQvMhCsirOwOw+eWMgOgz2mkO1J5y8sqn
7WhFzILW7SerwfbYU1pCAit3XVjQvBJlpT3A4akprp948KsFzqtQwS10Wv8BwDDsXp33u9rJ1tGC
hhHmnbpG0alb6rp5thBQ8j1xYdIELf0yQNsooIfOLmFoMEZTFyMEwtZIX3DD2Z5KW+yHZbwj8bOl
CP4wv7mPgrOFdltELFgOpUumY0m8TiplgAjF0S2BIy1Oxz0bxq8i+7e2+fOPRpFycc1CnCssLeOY
nFBpvm7FqFQvrC30R0XSHuToO3MCM37qc/eJIcqDYIVXqR/R8mMgjsAnx4i/ThOQPjo2gH2qDVoN
NVXgn2a3dKT18bGGvoeMBSnhTbDQvItMQzoi/XmHY6ZOP8nxpIOkMZ2kV5htisHGJ9x/NhJNs8+2
YAGIMAChDACWOja6qZVVRViYkZO9soVasmFtN8Q5RHU9qnoSYE7SEfzEQJFU95MIfL6r1lE8uUmz
d2GfXYX/y4kvS58yY0HuSRl9yi7c9C4cPjh63VFfnsy8l47jfvn2M98p8/yx8Ezqdf3qHTlmOV5v
dMWH9Z1ITpa/k9etjjtx6w22TU8XviVpFn+QU6dcZNaQtEtwX54K7R3tV9NXgLtmsQ0V3lm+guWc
G9pkiZKa09YZaaWetGzgqB91dt7sv9w2Z45vKmh32LlK+zFVJdcpo6MElppt48UwPa8oz60vyV2r
StVOz9hi040RU+/W6UjnFctrSDvz993VOcDM0zlYdOYjg7FnosoNcu4cJaExpuk/C8aETYW2ZG1Z
L5gSpIP3ER0WFbV8ytZBdGfunkor1IBVqyiwmt0Zd+M0llP37LdeKxV9MSaQDqolYKOj55LoC4Ut
GN75be37PNTOHeG8eiF1cLEoK2k+X1jt5a6z4T+nr7Cmcw8c18bcvFm/czNuFGVxND0rtAgAbinD
z9Q3bU8dT0QOt5ATCUFz6DWLq3yP2sW4TQF0ov8PAR61iveFHw178NAIDEfwQdzAFDoY2FPiT/Qx
/ddAHQtgjrnU5h9ydmQgjY9+csx7vdJjE46z9CLDXKZ/xoMjlvC+x+bf3P5DeazgrTysHgbz/sh9
lNt/NJrNJ08t+48nTx/sPz7N51H4pjvqXrB4dsrfvR+Ph+ktWWrkl8HpySiZnAUv47yXJWQt2FZF
X0/Pg63BBARoLrbWWNz9OnOVCq/S/NdpMpmkArqCt93RJPeXDg65mrDtVgtOj9i3s+D4dhy38wTt
awOMYdqWYBz8gCFdtd9voQ/ADy+TjJKg37bduMTB9vu4Rw577bV0PNEiHl/Ho+u182S0ZhyTsFZj
xq/hWjzRQqerb3UQsocwF/L0aqejGte6iEdHca+9EWyPrpMsHWHwwPbBz8ev9/dO9r4/efVq+3D7
ZbsZ7KV78Y0MY5K3J+gfhr8BuR1jIl72O53AxI4oygtaACa9iXj4OkV/ECyFcffeIkFDIp97lsCa
SVgcvHmNKD9sBlcFntF2xv3vb9tXIIskNdQFid18sK/78+B/ESAIie4nxf+NJxvrtv1fo/n0Af//
M+P/txTm20wRICM8WdFicsAWiHjOAvyf6Yja8zDMmi5XBDiAtgurijQ8YKOPdf4/Pg847/w/bbTs
87/xcP7/LPyfG0S0jB0sZf6IB9tNrpLJDs/Jg4zS04b24vtplk/aT4IX6aif4EjujVJsdjIdxXiD
w/hJ3G3OStJXjUOc5tAJpsLGrmJ47nYXnLzp5u/ajUbr6yKGTfFm/3Tn//Jj94GH+uuNjSL7/+ZT
h/4/2WisP5z/T3L+PyOARhkHZJ3wvAvH/VFYdrpDPLjw53//5/+GF8mk1misQ41DijiJQSEHyfu4
XxtPs3Gax6Iwv85maMbPc9aDIAdxsbYdT9NwnIxjlJmCQI+Q2Y6WOuJRwIMiv9w5LK3K1ZKBFkO5
Ha3cqdqzNUNd+WbrCDPN8CEphJAbomIUHJ7sdU6Otg+1wCDs4Q+H+ycH5lM+zZ2X7SgKXrze2tvb
3sWvwTC9qFTDO9yJ0WQQPj51xn8Wfp7/MnocRitfRs/R/pfpLrnKrUrqSRqgcJtbaUYh1wTiPFub
tVkUxu8TtJnq06Mn+CiQ8a/CWj+sXYVwihthLaXwomHtAjqUk4ngh1ovrDq+nVymo7CmXuB6YTmm
vsPactL4i08avwo1JXyVw4rCb799fPDz40WSTFERXBu0MhAFxG9mnfAb3pd70kwtkFcqv82NxFEB
13RT3iN4WQdqdn3aPKsGzPtWD7ApY3GKDVhVC48e/KJ2a/Prs8AOBOpolaUmWXPzLYrtiU7yyijW
jQ5qvVeaYv7Nes9grzQ6qFamk+QplBNbUB+lNxWxC/XppFetQwH0NMaL6tVgFsiA026oZ74qpxFP
/odDOFNRBE71oZ0FZuRqX7jqmdXsIBlJO+LSduXGWQ0okD3jzs3ySTWYXI2pTbxiSCaXZOzM8hNQ
YJyvwohdtwd08wxfWWzUxeKXlsQtTUaY/Lbd8kcwLYhc6olYWhypFN5kwDZ2e3SrxBIRVIODnwO0
o0lvRoQ2Nv04g1ADFbxK+yFICw373QzDesbd0XTMMVp2FdYGYa2m4RFRcpJ1xyEvHW7/tHMc4HZV
KuH2yc5LDPrWCKvV5+ijPiLUCJjsaorJSabkBo3jxMHgroVffx0MEqp/ehp+hl1a/YW//x7Wdp2n
Z2dmBzJEM+aO5RZJeKSmI4xBKrt7+pS6I1ekPmDiioZGzQ7YQiJ5WQYz3g/jjW/6nqR66Oq3NEqM
348puGoHJXMD450FlAwL49qSwQqDHxF4hRu3HB1u/1AB+i5tWdJMvdvd+5v+jl9iksUZU5CCoKCC
gMu0EzCni+kQuEDcm6jKUAa2MgWsCdACs8fQJOMbOKEVY/zV+vgGSxX1NB2J4jJyLkblzvROcKjh
F2FFzOLtD4cH4e9yUm/3j18vMhNKZbYG7NawT2aQPK8Os19B9MLQSLYIGuEuadKQip91uRlaNBby
x9RDxhcPko7Yeayl+VDQwPIdMOq2KuNar4Z6gFGNrq1a8akZvYgnzJ8Q90w0PG9QgyQe9nMRdI8l
r8M8tJhQne0SNqnZe0HbTYp4To+llddnmpVXMTSoHCKif60vFWeVtS3NP4KFY7WX92kGMYYejXjk
rFPjbtTdbp2TEZF3slgLt5NFMvvhk9Ys0nmfqjBTLBqrCKwjobqvxihChRij1Gixf5w8UgeGdFq0
U0Rf0AiRYOR63OgkgIv15rF3LPhtWHvawPXAH9+FTxuNoi4RSmJLRwq9EYOvrbB4wveLSGmVyA2S
P53Hl6wMGmjzDGm23CY7CqOnG9TKhIVPNKgTVSZSweN6KMK0gSRYF1NWKpiWuTYKHzfHj4EEfRut
MLIVVTUJRpVquaWApJpSQPv/hP+tA9AK0FGa8bz5ajBDE3wuRo0CEXUjxQvNmAqbtt5QgOEFO7UO
lNuxYhveQz+a2Ki4BuOhxjQUdK0k86tujtL4sDsdUQxpOFwuWwFD+kZt4TfIW7B6HaJDtD3QRVjr
hY8/P3lsj6f1HaaZWBvB8RYQA7vGW7hisqLWQHfBBtiqgJinDSUiFEqsF5b8TL2+IuGPQ8bXABar
6wQX91+qcZzRUgFDFHazuGyxoO/OeTLJ2yuVyrNH+pCqVc5UyjJAxRutls5a3mcTvYTcM7TAbFzI
SNJHAwHhOs4SoHD9cOWOA/lMQmtAB59kKCyqlbBi/a/cqRM6i0hJ81UcWBtdqwkKpZ2nGt6WM61Q
rYaRcCnVOtLM6zjIeu2V/2Aqn5ivZNYj0+TiFVTim76I7tCVLWAYkbsgzbVsXqFhgEfL3MBVnruD
QiuGVWChid8iYX7lLuvNkE3PenytS/tnTTv1AxoKa+QP1f/+AXrfxfS/T9bX1237n1Zj/eH+559C
/8sRlEo4KFGVqf89YqmABBIYpMNhepODLHk19WVFzZ+TA5kohlEVZUmMuCLClLCkItxtGGoIJfGU
/TEVxQf7qLo8ONk92n65/eJvnR92jl+ffE/JMzZrPv9kOF4iC4bQ+araGnrbrBUqeaGJo5+h4JvO
i60Xr7fNJnjj0Aq9hGZKkqpDS0YqDtJAa03PzKzrgYoEanaqnm/WYMVmOi+mFeMPSc+7u/3D1ouf
O9t7P8JivTLLwQMqc7ADxV92WIhNs4jxigofbh/t7/4IzzzNqTdmUV/L1kuqsP3Twe7OCwrz+UrT
lXfE83YDHmFlTB4EP/Zfvdrd2duGbwdbR0fHrw9P2pVqAMt6wO4FomD/cOeHnb2t3c7W4Q9H7Uq0
8ld0xqAQj4bifWfv1b6ta0/fmWX2/3YGPL9ZBiPomaXebh3u2S0hFJulXm3t7Oqlwu++aGFJdLtE
/y2Rogrq8Edh7Tok7b7GdrW++6JJvKipPgMGDJjyaEUsRBR+8QWq+fUnwAbDQ1S0ZQP9hV/FNkUt
MW+9Byzht98+Pjna+mH7cXCCbzbVvU94mtItck45fOCUT1KU3qfjzjgBOnQWBCcGZ52jJMWTjYUv
WYwdtFruT0n8lml5ALsQ2sjnZmXWLZ2R0wA8AqOJgV+61XAdu+7G0U0uuyp3sQr8Wg9CwmP4eaml
AnYHxFEYEy9YyHir38DNOuKMIH7fxXTEqn+Qp+180+iNC2sKmPIFlIPV4WuNa6i4NLYqv9Pgjyjf
Ea2ZleeIV8EtMz8/MjlRZQrFGhciU6giHyz7nIh8wtqTPKH2Yfu9xrqil6ZhMlU8BxKcI+Bp1d2K
OIA3/3V8vMb7BpLGO4ZVPsc7Sf2z/R4aDPtJ92KU5pOkl7OiFrNKRfdwmxDsrsYTViodDNB8wWjw
6F0yDmWMatj9Ka7+WhYP4NclC5Gax0aeKW9IRy2X4GNMqQcz7HNw4GPETC+AA40au5QoeU3NJ0SX
jyzpx3UqC8AhSStCIUJWt7h/DdAi1iHBL7QyyWK8C0HNIU5Fy//HNzkeju3mji7TGygNtfEtAOhb
DjwSLFc10MliWCfWusokqOU+FJCcxb00A74dEHZYRl8N8lkPd1BnpCJnMVy6KlNM5wEdovD4klCH
Hu2Eq415QANcRxrkYTcfn8Na34YHST0gzIcak5tLVPhXKiuPUKrpp4QcMWwzoumEhYjlZ6waaoQL
cLagV18hTWpGUD2/TAaT8PlzXovDXzUUNK7pFJHKI7YFgPVXHoW1izhsSSUHEp7wsci8TYHbyLBP
Vn4sdBrrz6VTCJ9DC+egIROcgmA2WkDWHOLchKGFX1Z5py9EJmWuGjYSSqpusU6cd3u8bzbFlpok
AOb9JggVfZMzWQyaiNMngvDvtctqSGSPN9IQ72GGpbtHs+mTyzZThhAt1vsleixlabmATEnVNFRF
bH7sfBITILF8j65+cGXhKAPfGvcfSyXCurjXAsFbwZ0QwLH3ogszVEcbLAgIz/1Uvkb6NUjDx2gS
ovSQuTwwz+FbDQ2npqR4sFUgLBgtNPiYJ8uNe/QzRPnkF75DXia/jbrEg/3IU8rixKGkzlr7ahjs
tfqhiqKoBBvUQBH/zmAhT/96RsYTsL5ic7bGYyBNdNUjAqEwKwrKcIyzoyAaMh6O3KYm7RK5rmuB
U7irs+LkMlS86dKD0GHyGEhN0yDDKsquD3VlnX5PuEq3ezIUt3M5RBdL2h2f54IJL3qsnMfKi3o1
RPs73aHaUZk37dsROxP8/W9Imj41+6zkWGoHT+gxzQJ4QA2I0WqECj9yT/9YhPaQL1RUENj6eMgH
8puuWHPGQOM0xTiOQOyHLOVZMrKGZaE8q5bIkLvMbM2ZPmfJCuxJPmeHxF2ElYof5jUtMkf3NHVt
ZbCEbEbFCoR+8CRxuiXLG9Trdzaqqk6jtBsGzjfJDM+yFZdQSRW3cbcgUs2hpPVbGWBxisXyhClG
hyMOyfrZyJwPscPMaTl60ADEENQtAKDRWgW025it2quzu/WGdiHDxijvm5IRpsdQHOPj5xL3CMLq
E/X1DldXZ+au6soCsbWWakGsr54ItsG2OwhtMsUxoDb8A/YkUdQJOWK+joqNH+TOdJhBHXCv4+lE
pJwP+W/HbgOJkmHgph8YGw4+yJhDM89QJhnTbAhMcZ1CzFjP6C7OesYV1AhP41SzWMNwXiJoFQ+6
wbJNKuS/uSFvY+1r4a3a37u13wCaOvXa2Vdr1m+6KR6nC1zTygDJ1QDTxsZZruzjtig6MHo3d4Hg
Jj1ap7XrUb9+AVzF9PwrLQRQhIbetS0MWoQVVLDBHSkxcPWmqPBTjQFEbWuc1H5U4ZBbjVar1mzW
WugOPWN++Hj+mF+9SlEF6wpDNRe5fsg91AfR5WQyzjfX1rrjhA+3DvC7RjNeu8M/s7U7bBOv1fnU
2/xvURJsqzP4SdQafssYTe1mgwxAAOjHAFSxNxeiEVOHlaN4OpVqHaQsYGsqZigdTu51wKu/Pj4+
8KeedrZ7IJJNYJ3wDgrXsZOZnWXa183J4e6yvWiM1ybrDeaWY14jf3+Vk1GC43lJU+dMDC3Rfx7t
72lPq/MHofJZ8QxDAtKxKb1/AiuGXzsgvcA+DBhwYcwG+LtpxVLS0t7ma1H4lXHi679O0wmaSQyA
u+sO4nYkdi6/7HozMlnZW6V9IZn+WBliXXsMaMJM1eQ3GhFUBjOJXHaryyxbWWImDsTQpMzApHOM
mkGAOKhMlcYXkf/M15hGkTc66V6oNM92GkNrtUR27AVXC9opXa3rSuP302btm7Nf+l9Wf6kX/2JZ
0ErXcZdpSS0lopEskUvl0BKfOmOYsWXtpwaa+KbKWFd/thtWQ9GTgna0Ap7mjLw/fBEVWSqbM0/A
isSLm0wYE1ONFIxLK4DjyuNFrK+UsEJ2PIEIN4K34DR+ELf5PbMtcHOGMDoZsY1QHIp29c2YPoMR
agoh1GKaXMMdxrdENCyXTXNNePTyfm6NhA+rKcu+R2cn1Swfc1Dk4QOUDtVFkSgJ6oxZgEFLZugy
AaIDV46paJDLScs6f1fE2FltaBzeHIk6i1cdmbpdIlEvIFBr8vQi4jQ3bLTkaIQ8zSC3uDqAfrsw
vzi3jnSTvKunGqY0nqtDwoO1ejK4+6z9Bqs6utRe8bR0y5AeVqU6T1+Ap/+5gRtU6nZpqacB1B96
BqXkMxMqPa4SdgxqTBkRx8j1TFxtFx0KOVep4gXWVdhmk6xX1IRmyIRoj/h9bWOz2UIbFibeY2JD
38m0NYfRPr9XQX3ZZjglta1Q87sor7hfTbGAd7B2w6j/RyDA5tUVA+ce5M0AaordBdBUCuoqeaVy
9Q7gZBzW+txQk6M0/pjZ+AiNMwmSPv1rE5Fn0f6RwpJ3dye6nq3xmyG51kYx04xATULVUqpgrd+m
pfRllox4RSxbV7fGVieiZVPJwHbhhDZ0SFdV2l0n3XEhYPlbYvqh4mlp5YjmIaK3xmqoLiQwWCPQ
DClRxSNr67vGF5nij4W1sdmL1sULpn/v0WWZZ6r+1nEzMPQrHRaK0qb78AEbzzz4+sC30e2EVyXf
g3LayuPPsDbIj3ZJfQSUJ2yxODajuDepiQj6TfS7gaIR2tZEK9gFO0ZuBzdw9PStxZNY+3Vf1OLt
FFRmRFSrrlFV6l60wpUhhToNoauAn6u0IqY64smZMCAvlrypqpCn75ZQC8y4e0WxkE0ZppSgvWEI
2qshFetTmejm3PXDMLyyLLmbe1ZJBGeyfEAG0Emrw/34ubTWQWFShF3XYaqbARYEdjJPp1kvpriB
IPqM4qw7AezHvyFupGvo+yvWcEyXWTpKfot5iAEhaTr6NasHNNLTmsef920bGufztVAoTb7mUJMZ
hieoX/xGLLtaoAUrRyae0BowGQRJf39Em91bxJBsFmRQIsT67kUXsQiRvIP92V9LSB8cus9CA42E
UsWECgom3ys9E29yjU12zTMTGD5fOBo6Iwe5/tRA9rbMIsbCF1EC3YCue+VUmc0yU935pRmaGUJA
7f1vA7372gt7hWs1DIk1rmEuXpC3MfREs2SI8XtyxvnAEcL/8vAglGgjkmRqzXM86+PbSNUl9z9/
XSM6B7lN0rnE8pKizNxSSBFxu+TgGPXWHqFtsyOQRS/V1NUh404iAFbMhl74HpC+St2VMKbdXiQ6
hLCNHG8YQwLyhOjH2Uhm4uMYtlmso5q0PDPE48W5PSi+ybmHTfQ00s/w7r4fT8hiBxHK+TQZ9otm
rDceLjVNQvZqB3yiP/UcegY5fyTGLrAQnwxgl98JC0gOaVgT77CYaTvwGjngcpBlb8uPEI6Kbtdr
IxM053YJgC56yy9jgBGA10n3vebWVAiKeDgQmbCjJGwfe8jMWwdElikBPhjIpk6R+gqDD5F+3/Ij
awCfDLZAkRY2Cnp1YUNwmcS9Gp06KMALAWGYvnMGL8ZrtDcPwDjnwdBUu6I7F+gGnqG05OO/jb6r
80RYIaeSRR2eQCWp2paTORtyIbmchRUlDpEkjbiePPETBL473gyZdHDzrZCx4IKWZt0bTkbRIxj9
OdHITKeobq8Sk6/cYV/82rMH/A5ZVZqshVHGR9UFxyzrW+RZe24Q6BISzftkq8f32c/bsGsRrkHg
BJoPU51hNQJP9y95p7HW7QJn2O2W2VMttoWLrLWXqtq7MQdvaGvvwxsCmHmrmwo9MGNF1o3EED4c
4evBI4Nyy96VO1ZkZkicrG3EAnIg3GBVBCQ3FniOaKEplaRmmwzJ6CDD6rjmZtqSZPFVikl8yCzM
Wnwdoeg7wOMy6M4cgpH5TO2F0XJkl7d2xYp7gytdAS6e4MqqWfWt9ziLMUp5WFLL3QF3d8vH7OlX
NGGb1XXxAOuViyDgje2SKDRjazz+yabTkBg9t3lxnWgOt7d/2n6xWWvMmAFS08FE3NBPt/Ez7fGM
ltrNglLKfkiq4v0Fy8wG72c6uKT5oFnc9q5xLk781SydsnkDM6fKYn3ZAFdk66jhfmb2mEitb6FK
lxu1F9JsdfCZglLH6wtzExzjU1j5QkwuJCMsZasJX/hHqekIuVGGeZwU8WONLtAiv9byt8hwr3FI
DCctnJzjLmUq6eG3YHVmkdVC0XmwDyA/eXNP3IInYQlQXhqEuYGuvuUa1JBugCltUDljaHARhXHr
bQbf/wbxXylkeT0Z/UH+vyXxX9cbzQ3b//frrx/8fz9R/FclPMXvuxhRP2TB7acZMdv14JElYJOG
Qrj9MH1IuLu1F+4cXK9jsJSUXnGXL2hsfIttcO8pDA8Wbh3shBiAbJX8/27SrJ/j5ewkfRePcsTu
5CTE09tB63xg9SA4vfp1MjkLLlNS6EfNb1r15tNn9Ua9tdGIwkdyCugJhkqaUZ+CThJBwVHxG0Oq
351oSr2ALhXaYfPZsycB0oV8jCNth5GWDaAZBb1hgrllKWJOZPioRcG7GFi+ISoM2+GTRoA3lnS7
0rlKRsAuD7u32IH+vPtePocKwWkXo2efBTEJZNgFxWgZktbkj5nvs8Yz7LiXDoeUHyGv38RAe+JM
H8WA8k+Os/Q66VPQrghvLnjBGmxRD+hYbT2CbR4C0EymFMtw/Zt6A5+kowvx6Ck8wRsHBCy6/8e2
oqA7TjAgHRNn4YmVViGPe1kMwrLWaYdXiYJhd4R2WNEgg83hmX8THj0Ye2w0AFpAQL7VnzafweM+
EGPzaeOZKo1/0LJ0/Rkv2O/e5lRIhk2SaafD5oa5hqP4Ji9fQCwBc4gowgg+mKTjGl5CIZeURwH0
gIm1cXW4foX96KVwrtgbmjEw5BepLBmjxhqmxH72UzT05xXj970hbELHeEhwQt/g1NJffTkpUOD5
LYN0nlx9C0RS1L6SxoBqIBBjDJHeMObrYy+0d70W3HO+Tmq/H4WvUvLClEt5gWUi3XWQBaHPbxKm
+CVsMkk3oW5BL9SE6MPcynGvcwGA6jkPRjHoMOlg6PS5JclixHu+oIwOjhuehXsWTC6nV+cjgEjC
Hujc+nQdNmlCi99iFNQqNB5dyBLNDW+J5D1w67R77DUs1f4I0Qdu85jcXmlkdVhl5inMHyC2RuRP
YDxIsnzyXNsIcsgdxTHgd0JBX4XdHoByThFOkCockxtslsCERzAgFgGnn+Q9dFtFq06RKxgQzK1C
a6Jz9J7i7piCaEElwA/U+BHbXdQoAMijCVcOMEMNKNrC6mHxU88uYcbfBEZ8dgYFGNLv9Vo1cqCB
JxaifoTXBNcMKuMhHMy0A6WxoEuwmq0n+EInO4/46lCk0HkHgw8wXxPj6WiVsWU/+WmZb0wC9JAO
4eHz8Hn4PHwePg+fh8/D5+Hz8Hn4PHwePg+fh8/D5+Hz8Hn4PHwePg+fh8/D5+Hz8Hn4PHz+tJ//
DwY7rzYAUAUA
