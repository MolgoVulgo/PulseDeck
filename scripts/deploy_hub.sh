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
