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
