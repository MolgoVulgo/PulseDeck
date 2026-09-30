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
