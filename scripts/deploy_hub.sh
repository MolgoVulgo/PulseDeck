#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0015-1
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

info "PulseDeck standalone hub deployer patch_0015-1"
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
