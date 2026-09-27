#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0010
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
GNEWS_KEY_FILE="${SECRET_DIR}/gnews_api_key"
STATE_DIR="/var/lib/pulsedeck"
ADMIN_STATE_DIR="${STATE_DIR}/admin"
ADMIN_PASSWORD_HASH="${ADMIN_STATE_DIR}/password.hash"
ADMIN_SESSION_KEY="${ADMIN_STATE_DIR}/session.key"
UNIT_FILE="/etc/systemd/system/pulsedeck-hub.service"
SERVICE="pulsedeck-hub.service"
RUN_USER="pulsedeck"
RUN_GROUP="pulsedeck"
ADMIN_PORT=8080

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
  for cmd in python systemctl tar base64 install timeout getent; do
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
  if [[ ! -s "$GNEWS_KEY_FILE" ]]; then
    warn "News activé mais clé GNews absente"
    return 0
  fi
  local result
  result="$("$VENV_DIR/bin/python" - "$CONFIG_FILE" <<'PY'
import sys
from pathlib import Path
from pulsedeck_hub.collectors.news import GNewsClient, normalize_news
from pulsedeck_hub.config import load_config
cfg=load_config(Path(sys.argv[1])).news
raw=GNewsClient(cfg).fetch(); payload=normalize_news(raw,cfg)
articles=payload.get('articles',[])
if not isinstance(articles,list): raise SystemExit(1)
print(f"GNews {cfg.mode} / {len(articles)} article(s)")
PY
)" || { warn "Validation GNews existante échouée; Web Admin permettra de corriger la configuration"; return 0; }
  ok "GNews répond: $result"
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
    if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);a=d.get("articles");raise SystemExit(0 if d.get("schema")==1 and d.get("source")=="gnews" and isinstance(a,list) else 1)' "$payload" 2>/dev/null; then
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

info "PulseDeck standalone hub deployer patch_0009"
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

