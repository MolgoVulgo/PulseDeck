#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — git-002-1
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

info "PulseDeck standalone hub deployer git-002-1"
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
