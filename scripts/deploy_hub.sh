#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0013
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

info "PulseDeck standalone hub deployer patch_0013"
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
