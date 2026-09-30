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
7ef28+/6+f8BcEURdwBABgA=
