#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — git-003
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

  write_install_metadata || { rm -rf "$tmp"; return 1; }

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

info "PulseDeck standalone hub deployer git-003"
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
AA==
