#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0014
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

info "PulseDeck standalone hub deployer patch_0014"
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
/dx+bj+3n9vP7ec/6vP/A7fC/l0A0AIA
