#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0012
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

info "PulseDeck standalone hub deployer patch_0012"
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
/w9/GECiANACAA==
