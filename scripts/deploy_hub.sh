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
j38f/z7+ffz7+Pfx7+Nf9d//B9xl5qsAGAYA
