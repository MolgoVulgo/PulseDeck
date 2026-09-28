#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0010-1
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
STATE_DIR="/var/lib/pulsedeck"
ADMIN_STATE_DIR="${STATE_DIR}/admin"
ADMIN_PASSWORD_HASH="${ADMIN_STATE_DIR}/password.hash"
ADMIN_SESSION_KEY="${ADMIN_STATE_DIR}/session.key"
UNIT_FILE="/etc/systemd/system/pulsedeck-hub.service"
SERVICE="pulsedeck-hub.service"
RUN_USER="pulsedeck"
RUN_GROUP="pulsedeck"
ADMIN_PORT=8080
MASTER_PATH="/usr/local/sbin/pulsedeck"

ok() { OK_COUNT=$((OK_COUNT+1)); printf '[OK]   %s\n' "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT+1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); printf '[FAIL] %s\n' "$*"; }
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
  for cmd in python systemctl tar base64 install timeout getent cmp; do
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
  if [[ ! -s "$NEWSAPI_KEY_FILE" ]]; then
    warn "News activé mais clé NewsAPI absente"
    return 0
  fi
  local result
  result="$("$VENV_DIR/bin/python" - "$CONFIG_FILE" <<'PY'
import sys
from pathlib import Path
from pulsedeck_hub.collectors.news import NewsAPIClient, normalize_news
from pulsedeck_hub.config import load_config
cfg=load_config(Path(sys.argv[1])).news
raw=NewsAPIClient(cfg).fetch(); payload=normalize_news(raw,cfg)
articles=payload.get('articles',[])
if not isinstance(articles,list): raise SystemExit(1)
print(f"NewsAPI {cfg.mode} / {len(articles)} article(s)")
PY
)" || { warn "Validation NewsAPI existante échouée; Web Admin permettra de corriger la configuration"; return 0; }
  ok "NewsAPI répond: $result"
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

  info "Installation des dépendances Python du hub dans le venv (pas de mise à jour système)"
  if "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check --no-cache-dir "$APP_DIR"; then
    ok "pulsedeck-hub installé dans le venv"
  else
    rm -rf "$tmp"; fail "Installation Python du hub échouée"; return 1
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
  weather_api_smoke_test
  news_api_smoke_test

  if [[ -e "$UNIT_FILE" ]] && ! grep -q '^# Managed by PulseDeck deploy_hub.sh' "$UNIT_FILE"; then
    rm -rf "$tmp"; fail "$UNIT_FILE existe sans marqueur PulseDeck; remplacement refusé"; return 1
  fi
  install -m 0644 "$tmp/pulsedeck-hub.service" "$UNIT_FILE" || {
    rm -rf "$tmp"; fail "Installation unité systemd échouée"; return 1;
  }
  ok "Unité systemd installée"

  systemctl daemon-reload || { rm -rf "$tmp"; fail "systemctl daemon-reload échoué"; return 1; }
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
  local payload attempt
  payload=""
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    payload="$(timeout 3s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t pulsedeck/v1/news/latest -C 1 2>/dev/null || true)"
    if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);a=d.get("articles");raise SystemExit(0 if d.get("schema")==1 and d.get("source")=="newsapi" and isinstance(a,list) else 1)' "$payload" 2>/dev/null; then
      ok "News latest retained présent"
      return 0
    fi
    sleep 2
  done
  warn "News latest retained non observé"
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

info "PulseDeck standalone hub deployer patch_0010-1"
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
AIACAA==
