#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — git-004
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
  for cmd in python systemctl tar base64 install timeout getent cmp sleep; do
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

install_app() {
  local tmp old
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

  local pip_log
  pip_log="$(mktemp)" || { rm -rf "$tmp"; fail "Installation Python du hub (KO)"; return 1; }
  if "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check --no-cache-dir "$APP_DIR" >"$pip_log" 2>&1; then
    (( VERBOSE )) && sed 's/^/[BUILD] /' "$pip_log" || true
    rm -f "$pip_log"
    ok "Installation Python du hub (OK)"
  else
    (( VERBOSE )) && sed 's/^/[BUILD] /' "$pip_log" >&2 || true
    rm -f "$pip_log"
    rm -rf "$tmp"; fail "Installation Python du hub (KO)"; return 1
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

  write_install_metadata || { rm -rf "$tmp"; return 1; }

  systemctl daemon-reload || { rm -rf "$tmp"; fail "systemctl daemon-reload échoué"; return 1; }
  systemctl enable --now "$UPDATER_PATH_SERVICE" >/dev/null 2>&1 || { rm -rf "$tmp"; fail "Activation de $UPDATER_PATH_SERVICE échouée"; return 1; }
  ok "$UPDATER_PATH_SERVICE actif"
  systemctl enable "$SERVICE" >/dev/null 2>&1 || { rm -rf "$tmp"; fail "Activation de $SERVICE au boot échouée"; return 1; }
  if systemctl restart "$SERVICE"; then
    ok "$SERVICE activé et redémarré"
  else
    rm -rf "$tmp"; fail "Démarrage/redémarrage $SERVICE échoué"; return 1
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

info "PulseDeck standalone hub deployer git-004"
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
