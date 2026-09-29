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
ufv8y3z+P5yKK4gAUAUA
