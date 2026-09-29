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
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
8+nn08+nn08//6yf/w/AVnKsACgFAA==
