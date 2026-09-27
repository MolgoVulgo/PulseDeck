#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0009
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
v/W3/tbf+lt//yrf/weT2mylAAgCAA==
