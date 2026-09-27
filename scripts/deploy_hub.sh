#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0007
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
UNIT_FILE="/etc/systemd/system/pulsedeck-hub.service"
SERVICE="pulsedeck-hub.service"
RUN_USER="pulsedeck"
RUN_GROUP="pulsedeck"

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
  --non-interactive  Never ask for missing Weather configuration.
  --help             Show this help.

Default mode installs/updates the PulseDeck Hub into /opt/pulsedeck,
creates /etc/pulsedeck/pulsedeck.toml on first install, manages the
pulsedeck-hub systemd service and offers to configure OpenWeather One Call 4.0
when the Weather collector is not configured. No Git checkout is required.
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

prompt_yes_no() {
  local prompt="$1" answer=""
  (( NON_INTERACTIVE )) && return 1
  [[ -t 0 ]] || return 1
  printf '[QUESTION] %s [Y/n] ' "$prompt" >&2
  IFS= read -r answer || return 1
  case "${answer,,}" in
    ""|y|yes|o|oui) return 0 ;;
    *) return 1 ;;
  esac
}

read_weather_state() {
  python - "$CONFIG_FILE" <<'PY'
import sys, tomllib
from pathlib import Path
path=Path(sys.argv[1])
try:
    with path.open('rb') as f: raw=tomllib.load(f)
except Exception:
    raise SystemExit(1)
w=raw.get('collectors',{}).get('weather',{})
if not isinstance(w,dict): raise SystemExit(1)
values=[
    '1' if w.get('enabled') is True else '0',
    '' if w.get('latitude') is None else str(w.get('latitude')),
    '' if w.get('longitude') is None else str(w.get('longitude')),
    str(w.get('location_name','')).replace('\t',' ').replace('\n',' '),
    str(w.get('api_key_file','/etc/pulsedeck/secrets/openweather_api_key')).replace('\t',' ').replace('\n',' '),
]
print('\t'.join(values))
PY
}

install_weather_key() {
  local key tmp
  if [[ -s "$WEATHER_KEY_FILE" ]]; then
    chown root:"$RUN_GROUP" "$WEATHER_KEY_FILE" 2>/dev/null || true
    chmod 0640 "$WEATHER_KEY_FILE" 2>/dev/null || true
    ok "Clé OpenWeather présente: $WEATHER_KEY_FILE"
    return 0
  fi
  if (( NON_INTERACTIVE )) || [[ ! -t 0 ]]; then
    fail "Clé OpenWeather absente et mode non interactif"
    return 1
  fi
  printf '[QUESTION] Clé API OpenWeather (saisie masquée) : ' >&2
  IFS= read -r -s key || return 1
  printf '\n' >&2
  [[ -n "$key" ]] || { fail "Clé OpenWeather vide"; return 1; }
  local key_dir
  key_dir="$(dirname "$WEATHER_KEY_FILE")"
  install -d -m 0750 -o root -g "$RUN_GROUP" "$key_dir" || { fail "Création $key_dir échouée"; return 1; }
  tmp="$(mktemp)" || { fail "mktemp échoué"; return 1; }
  printf '%s\n' "$key" > "$tmp"
  if install -m 0640 -o root -g "$RUN_GROUP" "$tmp" "$WEATHER_KEY_FILE"; then
    rm -f "$tmp"
    ok "Clé OpenWeather installée hors configuration versionnée"
  else
    rm -f "$tmp"
    fail "Installation de la clé OpenWeather échouée"
    return 1
  fi
}

validate_coordinates() {
  python - "$1" "$2" <<'PY'
import sys
try: lat=float(sys.argv[1]); lon=float(sys.argv[2])
except ValueError: raise SystemExit(1)
raise SystemExit(0 if -90 <= lat <= 90 and -180 <= lon <= 180 else 1)
PY
}

geocode_location() {
  local query="$1"
  python - "$query" "$WEATHER_KEY_FILE" <<'PY'
import json, sys, urllib.parse, urllib.request
from pathlib import Path
from urllib.error import HTTPError, URLError
query=sys.argv[1]
key=Path(sys.argv[2]).read_text(encoding='utf-8').strip()
url='https://api.openweathermap.org/geo/1.0/direct?'+urllib.parse.urlencode({'q':query,'limit':5,'appid':key})
try:
    req=urllib.request.Request(url,headers={'Accept':'application/json','User-Agent':'PulseDeck-deploy/0.2'})
    with urllib.request.urlopen(req,timeout=15) as r: data=json.loads(r.read())
except HTTPError as e:
    print(f'OpenWeather geocoding HTTP {e.code}',file=sys.stderr); raise SystemExit(1)
except (URLError,TimeoutError,ValueError,json.JSONDecodeError) as e:
    print(f'OpenWeather geocoding error: {type(e).__name__}',file=sys.stderr); raise SystemExit(1)
if not isinstance(data,list): raise SystemExit(1)
for item in data:
    if not isinstance(item,dict) or not isinstance(item.get('lat'),(int,float)) or not isinstance(item.get('lon'),(int,float)): continue
    name=str(item.get('name','')).replace('\t',' ').replace('\n',' ')
    state=str(item.get('state','')).replace('\t',' ').replace('\n',' ')
    country=str(item.get('country','')).replace('\t',' ').replace('\n',' ')
    label=', '.join(x for x in (name,state,country) if x)
    print(f"{item['lat']}\t{item['lon']}\t{label}")
PY
}

resolve_weather_location() {
  local query lat lon name choice lines=()
  if (( NON_INTERACTIVE )) || [[ ! -t 0 ]]; then
    fail "Coordonnées Weather absentes et mode non interactif"
    return 1
  fi
  printf '[QUESTION] Lieu météo (ville[,pays] ou latitude,longitude) : ' >&2
  IFS= read -r query || return 1
  [[ -n "$query" ]] || { fail "Lieu météo vide"; return 1; }

  if [[ "$query" =~ ^[[:space:]]*([-+]?[0-9]+([.][0-9]+)?)[[:space:]]*,[[:space:]]*([-+]?[0-9]+([.][0-9]+)?)[[:space:]]*$ ]]; then
    lat="${BASH_REMATCH[1]}"; lon="${BASH_REMATCH[3]}"
    validate_coordinates "$lat" "$lon" || { fail "Coordonnées hors limites"; return 1; }
    WEATHER_LAT="$lat"; WEATHER_LON="$lon"; WEATHER_NAME="$lat,$lon"
    return 0
  fi

  mapfile -t lines < <(geocode_location "$query")
  ((${#lines[@]} > 0)) || { fail "Aucun lieu trouvé pour: $query"; return 1; }
  if ((${#lines[@]} == 1)); then
    IFS=$'\t' read -r WEATHER_LAT WEATHER_LON WEATHER_NAME <<<"${lines[0]}"
    ok "Lieu résolu: $WEATHER_NAME ($WEATHER_LAT, $WEATHER_LON)"
    return 0
  fi

  printf '[INFO] Plusieurs lieux correspondent :\n' >&2
  local i
  for i in "${!lines[@]}"; do
    IFS=$'\t' read -r lat lon name <<<"${lines[$i]}"
    printf '  %d) %s (%s, %s)\n' "$((i+1))" "$name" "$lat" "$lon" >&2
  done
  printf '[QUESTION] Choix [1] : ' >&2
  IFS= read -r choice || return 1
  [[ -n "$choice" ]] || choice=1
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#lines[@]} )) || { fail "Choix invalide"; return 1; }
  IFS=$'\t' read -r WEATHER_LAT WEATHER_LON WEATHER_NAME <<<"${lines[$((choice-1))]}"
  ok "Lieu sélectionné: $WEATHER_NAME ($WEATHER_LAT, $WEATHER_LON)"
}

write_weather_config() {
  local backup="${CONFIG_FILE}.pulsedeck-before-weather"
  if [[ ! -e "$backup" ]]; then
    cp -a "$CONFIG_FILE" "$backup" || { fail "Sauvegarde de $CONFIG_FILE échouée"; return 1; }
    ok "Sauvegarde configuration créée: $backup"
  fi
  python - "$CONFIG_FILE" "$WEATHER_LAT" "$WEATHER_LON" "$WEATHER_NAME" "$WEATHER_KEY_FILE" <<'PY'
import json,re,sys
from pathlib import Path
path=Path(sys.argv[1]); lat=float(sys.argv[2]); lon=float(sys.argv[3]); name=sys.argv[4]; key_file=sys.argv[5]
text=path.read_text(encoding='utf-8')
block=(
    '[collectors.weather]\n'
    'enabled = true\n'
    'provider = "openweather-onecall-4"\n'
    f'latitude = {lat}\n'
    f'longitude = {lon}\n'
    f'location_name = {json.dumps(name,ensure_ascii=False)}\n'
    f'api_key_file = {json.dumps(key_file)}\n'
    'lang = "fr"\n'
    'current_interval = 600\n'
    'hourly_interval = 1800\n'
    'daily_interval = 10800\n'
    'hourly_hours = 48\n'
    'daily_days = 10\n'
    'request_timeout = 15\n'
)
pattern=re.compile(r'(?ms)^\[collectors\.weather\]\n.*?(?=^\[|\Z)')
if pattern.search(text):
    text=pattern.sub(block+'\n',text,count=1)
else:
    text=text.rstrip()+'\n\n'+block
path.write_text(text,encoding='utf-8')
PY
  if python -c 'import sys,tomllib;tomllib.load(open(sys.argv[1],"rb"))' "$CONFIG_FILE"; then
    ok "Configuration Weather OpenWeather One Call 4.0 écrite"
  else
    fail "Configuration TOML invalide après écriture Weather"
    cp -a "$backup" "$CONFIG_FILE" 2>/dev/null || true
    return 1
  fi
}

weather_api_smoke_test() {
  local result
  result="$(python - "$CONFIG_FILE" <<'PY'
import json,sys,tomllib,urllib.parse,urllib.request
from pathlib import Path
from urllib.error import HTTPError,URLError
with open(sys.argv[1],'rb') as f: cfg=tomllib.load(f)
w=cfg['collectors']['weather']; key=Path(w['api_key_file']).read_text(encoding='utf-8').strip()
url='https://api.openweathermap.org/data/4.0/onecall/current?'+urllib.parse.urlencode({'lat':w['latitude'],'lon':w['longitude'],'units':'metric','lang':w.get('lang','fr'),'appid':key})
try:
    req=urllib.request.Request(url,headers={'Accept':'application/json','User-Agent':'PulseDeck-deploy/0.2'})
    with urllib.request.urlopen(req,timeout=w.get('request_timeout',15)) as r: raw=json.loads(r.read())
except HTTPError as e:
    print(f'HTTP {e.code}',file=sys.stderr); raise SystemExit(1)
except (URLError,TimeoutError,ValueError,json.JSONDecodeError) as e:
    print(type(e).__name__,file=sys.stderr); raise SystemExit(1)
data=raw.get('data') if isinstance(raw,dict) else None
if not isinstance(data,list) or not data or not isinstance(data[0],dict): raise SystemExit(1)
print(f"{raw.get('timezone','?')} / {data[0].get('temp','?')} C")
PY
)" || { fail "Validation OpenWeather One Call 4.0 échouée (clé, souscription ou réseau)"; return 1; }
  ok "OpenWeather One Call 4.0 répond: $result"
}

configure_weather() {
  local state enabled lat lon name key_file
  WEATHER_LAT=""; WEATHER_LON=""; WEATHER_NAME=""
  state="$(read_weather_state 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    IFS=$'\t' read -r enabled lat lon name key_file <<<"$state"
    [[ -n "$key_file" ]] && WEATHER_KEY_FILE="$key_file"
    if [[ "$enabled" == "1" && -n "$lat" && -n "$lon" && -s "$WEATHER_KEY_FILE" ]]; then
      WEATHER_LAT="$lat"; WEATHER_LON="$lon"; WEATHER_NAME="$name"
      chown root:"$RUN_GROUP" "$WEATHER_KEY_FILE" 2>/dev/null || true
      chmod 0640 "$WEATHER_KEY_FILE" 2>/dev/null || true
      ok "Weather déjà configuré: ${name:-$lat,$lon}"
      weather_api_smoke_test || return 1
      return 0
    fi
  fi

  if (( NON_INTERACTIVE )); then
    warn "Weather non configuré; collector laissé désactivé en mode --non-interactive"
    return 0
  fi
  if ! prompt_yes_no "Configurer Weather avec OpenWeather One Call 4.0 maintenant ?"; then
    warn "Weather laissé désactivé"
    return 0
  fi

  install_weather_key || return 1
  if [[ -n "${lat:-}" && -n "${lon:-}" ]] && validate_coordinates "$lat" "$lon"; then
    WEATHER_LAT="$lat"; WEATHER_LON="$lon"; WEATHER_NAME="$name"
  else
    resolve_weather_location || return 1
  fi
  write_weather_config || return 1
  weather_api_smoke_test || return 1
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

  install -d -m 0755 "$CONFIG_DIR" || { rm -rf "$tmp"; fail "Création $CONFIG_DIR échouée"; return 1; }
  if [[ -e "$CONFIG_FILE" ]]; then
    ok "Configuration existante conservée: $CONFIG_FILE"
  else
    sed "s/@LAN_IPV4@/$LAN_IPV4/g" "$tmp/pulsedeck.toml.in" > "$CONFIG_FILE" || { rm -rf "$tmp"; fail "Création config échouée"; return 1; }
    chmod 0644 "$CONFIG_FILE"
    ok "Configuration initiale créée: $CONFIG_FILE"
  fi

  install -d -m 0750 -o "$RUN_USER" -g "$RUN_GROUP" "$STATE_DIR" || { rm -rf "$tmp"; fail "Création $STATE_DIR échouée"; return 1; }

  configure_weather || true

  if [[ -e "$UNIT_FILE" ]] && ! grep -q '^# Managed by PulseDeck deploy_hub.sh' "$UNIT_FILE"; then
    rm -rf "$tmp"; fail "$UNIT_FILE existe sans marqueur PulseDeck; remplacement refusé"; return 1
  fi
  install -m 0644 "$tmp/pulsedeck-hub.service" "$UNIT_FILE" || { rm -rf "$tmp"; fail "Installation unité systemd échouée"; return 1; }
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

weather_enabled() {
  [[ -r "$CONFIG_FILE" ]] || return 1
  python - "$CONFIG_FILE" <<'PY' >/dev/null 2>&1
import sys,tomllib
with open(sys.argv[1],'rb') as f: c=tomllib.load(f)
raise SystemExit(0 if c.get('collectors',{}).get('weather',{}).get('enabled') is True else 1)
PY
}

check_weather_runtime() {
  local state enabled lat lon name key_file
  weather_enabled || { warn "Weather collector désactivé"; return 0; }
  state="$(read_weather_state 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    IFS=$'\t' read -r enabled lat lon name key_file <<<"$state"
    [[ -n "$key_file" ]] && WEATHER_KEY_FILE="$key_file"
  fi
  [[ -s "$WEATHER_KEY_FILE" ]] && ok "Clé OpenWeather présente" || warn "Clé OpenWeather absente: $WEATHER_KEY_FILE"
  command_exists mosquitto_sub || { warn "mosquitto_sub absent; Weather MQTT non contrôlé"; return 0; }
  local payload attempt
  payload=""
  for attempt in 1 2 3 4 5; do
    payload="$(timeout 3s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t pulsedeck/v1/weather/availability -C 1 2>/dev/null || true)"
    if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);raise SystemExit(0 if d.get("schema")==1 and d.get("state")=="online" else 1)' "$payload" 2>/dev/null; then
      ok "Weather availability MQTT retained = online"
      break
    fi
    sleep 2
  done
  if ! [[ -n "$payload" ]] || ! python -c 'import json,sys;d=json.loads(sys.argv[1]);raise SystemExit(0 if d.get("state")=="online" else 1)' "$payload" 2>/dev/null; then
    warn "Weather availability online non observée"
    verbose "${payload:-aucun payload}"
    return 0
  fi
  payload="$(timeout 5s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t pulsedeck/v1/weather/current -C 1 2>/dev/null || true)"
  if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);raise SystemExit(0 if d.get("schema")==1 and d.get("source")=="openweather-onecall-4" else 1)' "$payload" 2>/dev/null; then
    ok "Weather current retained présent"
  else
    warn "Weather current retained non observé"
  fi
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
    local payload
    payload="$(timeout 5s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t pulsedeck/v1/system/availability -C 1 2>/dev/null || true)"
    if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);raise SystemExit(0 if d.get("schema")==1 and d.get("state")=="online" else 1)' "$payload" 2>/dev/null; then
      ok "Availability MQTT retained = online"
      verbose "$payload"
    else
      warn "Availability MQTT online non observée"
      verbose "${payload:-aucun payload}"
    fi
  else
    warn "mosquitto_sub/IPv4 indisponible; availability MQTT non contrôlée"
  fi
  check_weather_runtime
}

print_summary() {
  printf '\n========================================\n'
  printf ' PulseDeck Hub deployment\n'
  printf '========================================\n'
  [[ -n "$LAN_IFACE" ]] && printf 'LAN iface  %s\n' "$LAN_IFACE"
  [[ -n "$LAN_IPV4" ]] && printf 'LAN IPv4   %s\n' "$LAN_IPV4"
  printf 'Mode       %s\n' "$([[ "$CHECK_ONLY" == 1 ]] && printf CHECK || printf APPLY)"
  printf 'OK         %d\nWarnings   %d\nFailures   %d\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  if (( FAIL_COUNT > 0 )); then printf 'Status     COMPLETED WITH FAILURES\n';
  elif (( WARN_COUNT > 0 )); then printf 'Status     COMPLETE WITH WARNINGS\n';
  else printf 'Status     OK\n'; fi
  printf '========================================\n'
}

info "PulseDeck standalone hub deployer patch_0007"
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
H4sIAAAAAAAAA+w9a3PjNpL5rF/B5VYq1EamJdmWt1xR7lzOJJm7ydg79iR7NeViaBGSmKFIhqTs
cXz+79fdeBDgQ5LnoVwS8YMtEg2g0egXGk3Q3f/sk1/9fn94fHSE//HC/4Pjo4G8p2eDo+HRaDjq
Dw4AbjDoQ7F19OlR++yzZV74mWV9liVJsQou8UMvn/sZC7aB1dYud3++vPnEPPAe8z8aHu/mfxsX
n//0Ps2SX9ikcItkEX3sPnCCR4eHrfN/dDSqzP/h0SHMf/9jI9J0/cXn/83NMoyCvfw+L9jiupOx
X5dhxnJrbL2xc1Ys0yJJovzr8fGRfd3hsDf+5C2LAwDRIFwq8xas8O1O541gp+tO7C8YQqbLKGcB
m7zdA36zO7csy8MkxpK+O3T7didg+SQL00I8vUD4bwDeeuXn6Q3LsnvrIrQCv/AtakFiupfeF3Ne
5+vxgTs4xKZSwI/Fk5APpGPBZaf+PNlb/FoUX4+H7qD31YHd61yXqLq8+/y6Y6Bq4O7BA3fhh/EJ
/sFx4thdjQop0MafsdydhnFw3bmbs4xxWmYTIODvPdv1i8s/YPcJbcCT9P8QygfDw0F/p/+3cZXz
b3D5R+WGzef/6Pj4+ADmH252/t9Wrrb5RwXnpvcfpY819v/goH8g5x9UADwfjI4ODnb2fxuXbWum
Fu0diwswtWkSxoULhZ3ONEsWludNl8UyY55nhYs0yQrLj+Ok8NFc552OfJbNUj/LmbyPktksjGe8
idQv5lF4I+tfwK2Ey8NZ7EfyrphnzA+wHq/oTpIoAgudZOBl+DmTLZzJx3WwOwats0xC/sRv6xXi
aTiTQN88+/b09Ysr7+z85bfPv/MuTq++78EI/MDjcKKSGJNHRl/W5RBIH2PILrob7iQKgagS9Pvl
zQ//uro6o4edTufF+XfgIIhq7owVL+AnyxzPQ9fJ87oAE7Cp5RFlM6dr7X2tCO2eZrPlAhq6oMIT
8nQ4IDTaAuWAxzMbVzyyrlbV9YPA80UdhwrIg9rb4+MEx0k+K+5TNsapLB8Bsv4yKsZN9FRAcxal
46l9df7DC0U8YiZiE8sRjZxYDw3NPHYFBhzpDGYiiwXuglqovjipgI85WWBA6A0qOrr0A8eZO7yh
2iyK5yAQJwpzwTRjnTUcbESwE6/C3k1YWljO+eWzLEuynvWjHy0Z/e5afo7lZZPAAi7DIsc+M2hB
D0+sz3O7hzW6qoYY8rBDT/IiST12i0w2LqXHfYZPYAgdMSsWuswsLzyEd1DmloueNc2AzYhSL5OY
nVjW3604+dU/sU5fvgQ9bSAZxtPEsS/nyyJI7mLZHgusm3shwxxX3naJbokg+soSJV7D5f8ccXf5
/LurZ69+6BnIdlfCP395VQUneBQ+Twjf2JQ7h88Vyaece6k8TqwozIs3Sllco/9+TUDhVEy/VDAu
i/2biAU6eygl5Ke4DHGqyscxm+jpeHbrqLtonwrBidMkK3sA1tbRrqNgVDWYWJuQOz9UrYdA0UgD
q3WXMVy4scAp++2W4NXOgctKHjCHpIoEJ/dBboG6UulZY1h2eR5KsefZvIfMD0H3X9JC9dk7QJrL
ePf/4aLqD3S1+X9z5kfF/OMsA57u/4+OBqOd/7+Na838e14Yh4XnfdBSYF38r6/if0fHA1gL9If9
0WCw8/+3cYGLD5YRvPlA0/R88sFK+AWzREiLFgO/N7a762Nfa+SfWOBD4wDr5H9wMFTyf3TUR/kf
HO/W/1u5UP4NaY/8CZsnUQDObadzVlMJbOHHRTjJYTnFYKFQgNP4ji8AYOE2mVs4nW5npyv+KFeb
/JcO/of7gE/3/44Ph8Od/7eNa4P5T7MwLkAdvLcVWOv/HR5V/L/B4cFu/3crF8Z/+fxq/p9uBHaq
/E99bSD/GHP/pOu/g4G+/0P+32i0k/+tXCDelzQqTfyjcMom95OIYbSzyPzJE3aCCKa4T8NYbaxc
ZEmRQOudTmcS+Xlebtw4skgEETFIzWOWOYumWlDadd2OBoHh6zrA703KP+S1gfwvwhhYn2W37+sD
rLX/o0HF/g+Hx4c7+d/GBYL9A8zvHp9fS+Z27XyBv8i1gfzH7C7/tPHfw2E1/ns8PNrJ/zYuEOmX
ML87gf+LXpus/yfezF98QADg6fs/g13+15YuXP+fWTS/O+P/F7w2kP8P3gNeb/+r/v/gqL9b/2/l
MvI/6e0KLYNpJ/J/+msD+Ze5bp8o/n84ODxS+z+j49GIx/9HO/nfxgUifp6yWCQpWucxs878KLIO
3b7mB2AioFITTwwGolKhuB/LJZB6JFO+f8mTuJo0XssGlw/CBWsKM179z8Uz7+z7Z2f//fzldz3r
NL7nUMssisIbnmCrkrCvri5EYu7rVy/olwFMqcESGJ6xeJIErIc/eYK7DixSTyX4K35LwAmQVmax
V9LNVVqollvO88VT/x5zixW1eOeeeNyz8mSZTZjn3/ph5N+EUVjcy0JKojQIwQOrevMfmo5+ef76
1dkzfC8ORyeUw14Sswnwzd6h3Tm9eO69Oj+/QpB5UaT5yf6+n4auBr7wUzfJZvvICPvAavuiOlR+
8eL8p2ffeNjI9+eX1EhzZVvFkwUpaRqdV8sYOYSnWvPRA7+eWrkPTkz4Gwss+XJAmiW3IXi2Fjq6
y5sonPCs6ynQFXias3nnPxWzOkDF31g8vsqWwAp5lBQ5/e6aaLxieQrcz0RIG2qLjOIgnBRv8iIj
3rzmGcURdFksA3ZiTWH+Cv4siWe1hzim3yjUDS0YT7xkOs1ZcYKZ7lQQs3eFB8xHoNb/UoQcyIj/
5LsE8XJxA5N6i0npJ1Zygy9Aymx5qEHdiponMvM5zMMYdGU8Ybxez7pJkqiL1MM8kHqxA431eFtd
LUtYZPwSOto9VVL4UVq5l2ZsEqYO/E2y4MQyCdiz3oZxQINciXrm38HoeRvI0A5W68pRVVAH4B71
sx5hSUSoQs3ag7ndVW9rgLAHIbJTC/aEcvmIT8H1asRtwbn2SuyR19SsYBv1CYKnb/rXawcaFmyB
GBC0GHpOb2XUER9bD48qRf0tu8dscccOA7tn2fSyLPzXXvHF2xBoZGvdEwdAQ9gtnyh2X+aPN3Kg
QziEmDhPKYzNjEh8aqap84G8gR4Qdc57Ggl4MVJOl5oo4RoCplSIeFXme+U7JAEpzJI9ayQ7WU/R
8tUb0BP2iSX7daXa6GkQQEwdQioRDURqDB1OPmsAE4qlCVoU8UqP5rsR5dg1xiJq2/jUxpFVIOuk
FySPE9D2EWhtb7LMMnxx4yOSXsiPGhyp6hJnet3AMC22QEJVof1RYO4cGiJNb8uXGlBmSXi1tqUQ
Cftd5BXpDopWwVZVOLM/Ecu5TwgCl4eBRb1opmmFKIOhJQfL4EQQzhRYgv6zzCfvb6K9EWZPGYty
LwrfIp9pdyYUqPY8h7oII39789TXYebLRQhK9B5h5G8vnRQ6TMDuPHpZEYHUjdnX8jbEUvynPZ1E
yTLIsYD/qrZ8C/Tn3hXClHfeQoe6A2Pi5SljAULR3SLNaxAzWGYoALxphArYTAHhb608X8YZTDUW
y59mKZdU+UuXTNTIgoFA3/UsWO8Av3lCSYtJdlHr5k6DOlZ2rmTVsrWuoaB5lTAn9i0NmbxICMre
S80r3++JqbsG2w/WAouFfORxcrcCEotLSaJmG1EidKhdbzD3FgvSTHgrq1I/K6piuVYVb+V7hNz2
I5JVR0AhpgqqzaoCqSr5HaeSH7Gspjn4QzFmuvHCgI6+IBOODEA/gBKivmlNsbBH6vK6UsLBpVMB
oszwXThdX2uqIZ/M2cIHLhzorEm8Ag/5ukG3Myh8IKwOWhUyLU63W6vpEVipAHWLx80xFNdNc80c
6C2Tqj4hcmtPFeGgSP2WglS1R3NAKLp/qjnqWVgvp2GvMk2qn6C2dhBw2luJOL3C4tArerrJOaH+
rrU3/9YZH8Gdmxogwe9FGAsPiuoDP7VYFtuczsfy/cAGY8PZZI3BIaCNjA5BbmB4CG4D48N5ab0B
IrhGI0QlawwRwWxkjAhyrUEqodYZpRKy3TCVE/ieZgavp5oavNabG4KC7hpNjgRIk7S5YxtKbNO8
IWxrb9QTVqLpI1OSLOPAoQWpA8+71j+sQb+vvcS9scHDa3OjJ7BtN3wlum3GTzTRbgDLJtqMIF4b
GELRU4MxLLtoM4gSqtSW8p1rrNfdkpl6fzNEuhmqlfi3WZvAD9/H2AT+/TZtDXb3RzA1aEkqOJGR
aQs2YGEtWCKpoWIdMHoKdvBYx8J/h//icDYv8Ae7ZfQ4yYyYh7yqGhC7VDGQbl2tbaT8JH3eTA3j
+QBtPoKBqitDspsVymiWtY0+BLIxgd6XJNTLx6SJ5iW0k6TVLflj+hFb9g4IZuXSVUI0LV9V+SJJ
VBPqdwOMaET+bIDw0rlftiPudt7MR/BmSNSBA7isZyLky92SSuzVvxPuS1tcXsPSjFqLepW9habQ
rw7cEP9VY5zaD9jvY+kCyXoGPIvacWnQe3hhmBQtvD4hqpa+Y1DDa1rW3VSXiUGUfphsYeeLbRoS
uG9zxfjunrZLzjdLy1dWZIIUvZQiezkxd3jLd1VK/wig5aawDImXb7l4fhqikJdvuoB/U1Y2jvPB
CzXTWG/TFQ140zBiLm6iewV7Vzi0nQzKa2wvi+neP+2uCw2H+lE94vAqcXZV7bgqmsl63Hlqn148
JzSwQ2sZiw3qCLzRhza8Hu0u35yGHqo+IcCs7dRIXpD9g9CAuwMmt3ZgFpRqFBYb92La8OAxL8nU
zmnP+kePv410IvYWtY1UmpDGDV8xAK01fgxTfhcWc0dtiFeVIqUV4JaBTDFwtBZqWpFDuyQ9zPqb
3Gi3aSubl82TvKDDd6G0uqleVyVNpFX745x4gJ0fw7Tm/hQPBZmFMd8uf/3qhW0iCBjDQDT8S86K
clYbt7/I1+1/yUvsg+ncVN8KK4FJERjA9V0xBb0EGSbvacFAHqp+l+g9ntW6j2cNkOgfBBJUiXLX
hHysTisxymqdz+kFy24E5Stu/NVAfzAKMhPjcf9Bm43H/3hQKS0Ob6/7aHc0WeH5LGOZyuIAeA9P
gABmyMcP9ukE9QOSCoYp0yb2MYcHTf7rnGV7pzPGPVmVNbTfd4f2Y7ddgaF8yJwZJ5NJNKjjk2Ux
1mkuz3oTZXSgXrk2VgfYXR4M+jX63STBvb4xh3qxrvpUftDmyk9XRFjdeoB6LtK4UceJjmT2UXM/
zM/JXoOz4BdF5gAEBoboMZCaFNHTMItZcZdkb+XJgg94fqPDG+y66vQ1jB7xvini/8Uyfgt+XPzF
qpFc8cl4EtUM1CTb4awGFjSld9bONjxLApnPpawpB2e4NqEOAfzX5flL4EWYE5n8FYd4pz2rn864
Ge5CQ4Yx32XFnlaYtjUZJ0/qkpQye5eC0oQ7ydiaSqasXvJsRfyl3KhuRon2RfiWz1NxatkXt/ws
8+/lxjNeoLZ1nFCv9xr1eoloRLJQViEZaNTumpYRCQt6RZUGAbJk10FFbkNTDZkR0bP6q+gHqFdX
KLgDVwFoykrZlL64oy9ZTRJq5ZQCadaghAAfDSU5EStxUqknPFGjnqZUzTZpiAe+F3qKKfBrBRVp
kMlz+vTjs8pIJJRmq5tWoRKOD9FEXetJZVzhNYmYH3tCaOsbuFTQtH1LOuS66vFWfFSnbF1wAjJj
V/0GM9CzyompzYBEWjtVVmbmqHVKq1ssUOI+kXS+ZbqKrTWJ3UZhzIRnnhcsFS75JFnGRRnSbu2K
b5ZUV4plsCLMyMExUZnasuP9B+zz0RYLgDE0p68lcMmMcVJUkQ61RRFwbbOGMdRVDyqVjYLexjyK
Vh6bOI83KR+U0R38sgQUl4fy3s1xqRUxuY7Pu9ZXnEacG2WTeMNrf2WNqg74jNUoUU6zDqqjj9Uq
GVNq8IVP8XVz8E1hDg5JMhMTzZpjHGJsZkChCRCbwMOrHWq42yZuhHuNuiWFv9RJXCQRy1DMoOI/
R4f9PkecpXRG7QCD2txLOhj1S3eTp8U3CrBkn7oMl8Tiqo6mjYddAvT1vx4TX++VOF1XOnTzJKP4
+DjyFzeBL7ZHUA7Kdrq1ZXFVSZizTi2/OSG2ujZXMJxRm5dgoqx5xcUL68mH9TIj1bA6meXTbjUb
XB0y8rQ4jXEcM6xfjPx4e9MojlGIDUKR1q5ZrtbZ43qQydEPFVc16JTrxrO+TTBebgBe0S+HB5HH
QuqXYPvR9R/LDOM99eqHjbuIbJHEItXd7AAIXnj5EtaDed4QJdHPbKmf6qLaUkeLm/H6S6yDey/S
mJvvo3yeW87n7iFMJP7tVtbrpl/Il6i0vEE/wy4DgZYKGa6o38jfa+IKzXOhjuTWKFM7zaZhssW5
6bIAVZDeaph74NncsupWhAH0SxLGjlxPc3u/clX9pTV0+9Vh0IsS+dx4+8SxQUbRbNo9sW4c22qu
CP2UBbp9l61I+76cTsN3wsKLN1kaIkINBBJOpRIzV6IHig3WHwwsAbXdq7xE44j/3fXu5NRG+bdE
w3pYk7jwgXfw2DQ8k0jSl/ELVsYXObka3tRoGKzAGY11+xtApgxRbxW2pbrjamgdL12ax3UBN4HF
RPN/TWy/fm6kttnXB2IrFqjMDWqJgN0sZ44tFYJejzoTXeCBpGziL2EuafLAS9fmzZiqKSsmc6/m
w5qUV6uIsamxXVmvRUrKEUont7cipb26mNWUVneV4l3l6K4U2phktlvXw4rAMpV8mYKrV5FhTjmR
B/lUwikPH/fAzIHzFqnh3OAm7uZqGSfo7LbVrPPOnZ/F+E0PNTgOXgZSPg/2Pw+kewZI1fvbBNEW
BuDAxvxXUkhXTP+KflfNnhigmLwTa83o6pPL044+YG55yoeOPDXp4W7b0+a2rLfBzBLw+09sE44t
00qgxqyaqVobT6rW56op5SN7nxkFJ2+1m7GpZc+FW1YNmkhdMea3gvnEHcd7bPXdvsZARQZDZpGP
JSMsqixslf3gPhB4OeQGVfalq3YGKBpTMJR/20R6PEfgzNTXlyqhzFxfUPiANCq4vkmRxOHEMdeT
Yrgevi1KG3ff+rAKrGN2R8s2jUB1HGoxbXNiTBPVvPKtzgB0+6XBXxJdOur11o9qrYhAue77NIbC
5dUoeBIDTpSmLxfVh7ch3+V8/6MhX6J1/BqDNVaqTSEucTrVKTSh6sQwuX3hv3O0Jz0DszruhnCo
uvRgVdX6PqpAVuc3jkHz7LWyHF462wkj1Uz1+vDrjCesVSvf0XCeyHt4rTLpm7FfG/Y626yjMc3U
B5KYW4w1OEoeqROYW47t0Jdj8UTymqi3UjeANSqKPAoCLFR15u9ZdZGiVruVFrgpQTkauP0etXPQ
x1+q8b2aVq9oFM3ekPmgRv+8H5lq/f4nWNKP9RHYp5//Pxoe7L7/tJVr5fyDEISTDzv7E681538N
8LBPMf9Hxwf8+y/93fl/W7nw/F8MkdBU02c5WZZTZAsUfnnmj/XjgCLEeepP2OYHANFrLNS0o2qL
4JcW9DOzG8WexNR+KDvkGYpf7H/RfdwXETc30h7aoiv+GXvTlTQ7tvTvue/fDuzGzisoYyIztWxG
qnDP4er84vmZd/n622+f//vZpUpakwtEAxVKkm8MeZl1ZLBIA1fxIxNSRBU0QBlnMOH4MlUDE+tW
DoUH/NYQxYeNWBJ0BOtP/noAwYlbASEPDK21mU72qaCxXVUr8PP5TeJngVGlfCrg+YnVHp1OXu2I
l9HJ5Y196XWN7vSKtR7Fh1Dqw+LPm0cl6mAkdpnr0OJJBe6X5EYHwtsKRDFfLm5i6EmHKx/2Oo9P
cVZW6n/xuc5Pq/8Hg6H2/ZcR//5DfzTc6f9tXHj+I2j8ELQbrJzJFIj4CR2FVbMDwBtP/iz4Rie6
yZvUnyfGQWWwUMHblmPUaHNWP0Otenpa8zFpG312m+8nGzvAazeTS3zea684Z3mOAUIKslFMYnVo
X8W61u8Gqy8hE3HF9rIZ0vKjCM8Apnxl/NAvYDLm0KLk9OL5j/y5++OzV5fPz18OzV0h3okXBmMZ
d5IPTLhUfPiDN49Euz0YDKptYaqSoAg/da1td1UoKiCcIIjKaCkftdUIwryhUvl0TU8UF2rojp43
1sWILQehtSXFNI2Bg/XhRZKIZQ1VZJIKVrytNWTROuLxT1nTp89BDuqSYSvJtLtaIuffrVPrhZ8X
1k9hFAELxfTqBq71UXGIPBiNxsjGlJ7jWj8X+c8IlTHQM0xrUabI3M1ZTM1Q23egCdKMpfS1GkyN
gfoevvf0M4z/LcsB0i8s9g5T0sPCLWPJWHncqAgqGQcq6FiJCBgyOW4S1Ma9UbvUpEDWvPpCoqLE
Bi0qWBrw2MYxeRPoB3fl1s0sAde4TL6No5OF/N6KpHJKjbERs+TXJB8PqgPHrd2arJZKs5QPqTcJ
xZ61BM9LZiX6s1yGfT1+7iaoC1iXFCH7v/aO/rdt3Lqf9VdoLoqzB8exYztNs2por02uwbo0SJor
DkFgKDaTarUtT5KTZkX/9/E9flOiFCc5ByvEYddYovjIx8dH8n2md8hUL63X8WPQGvCIjnnNEWEW
o/a2RwmS9kdIuLTGCkRFStsA/Cqx5HjsPuHg2ZZRh9Lv34VU5w+mVE0BN7+MYUPixz2u5Coc6yok
IyKW3pNqtPmEDnaSMfgyyQ1jtHd8TC9eb9/unZw4Z/YUmRq9z0kDDoY4A8W7fjIOcKo5nAINnIl9
nWAoM6LNP093n6d/N5rFJp1IBP8s91s4urjflk1A8WrDJeBYcndYUhWUbsiK7cUUZhB8QOiEKIqW
WTyjJ8QxEwXT/87QVSCk1a9N4wxjH3YyDFVl9GDeUTHQFViLiQ/VR0ouyl1jelvGY/JaHqUQzrXa
aK1qbacM7NiUsfMhdsfQHIoTXPHmIlAfprfzsZtnPITcvxK66YN5W9VGN43jxUha2El05I3CSszO
hGUW5VPMojHwe4hFcI5QWMS4+YyjhL5o2Nf84SQ7vyBTfhjSrA5NWZpGXlKVrYiwWO3NJVWm1hl5
ATNzRAdAHYsKZFItTpM9YjuDjmSxPShY7RzHRy5P/9/WefsDObq5oAQ757pbZhCqGLneuRxTd6PP
Vtnhp6AGGlEA0vpDWBQY5pFcx6aHn77rGHCCkhkjG+n+xsdkDOYOY+APseeUcqRF3F1tToVpaRX9
rXJageI4XENZ/YDNBsoO2VcJpenLJT3hfllmk/jGtuRt5WbUQdAF/br7mUdDSfG5B0rB2YeNpOD8
k+96oUJ5BQqFUkmlUPKUyufONLgcx8sp83i6IIKG0fISbnO+nI1iVq3t66W8PIbABE8tJPuJS6n8
V8jSHigBrtD/bb3obtn5fwe9Xi3/XUeB/L8Z3pEEQxc6QLgB+xe3muxXKQrTlWXAeoYPJu9FhV2x
Wb7L+N9W06FT92Q5W6RNlR0DBEQhJK4Jmo02+Pjugj8VOEZBDIaUp28gcwzYFabjKApwBxWh+93b
mWa7j7//xv6xdio8NbZ5Nx3W/ey1FOoUuM5YNUYy1wEoMMk10wWaSGEOdRkRDnXfpZBAbb4/7NDh
v0P8KOHpsKRIWcAUwVFWZ/V85N/x3x+cpbsny4wYXhzjB1qCABmmh0JxhB8YmkQFWPMjotDrTlRl
Hn9GQ4gz2pqJRL0P5sRxwNbTlh5KW97/cl4ZZyIsAwaRwj91SnW4nwi1dZU/h4vy8DvteYU/ViVV
/j8TlAgaxf64L6lZs234WRQGZpHzr1dFKoCm9YetP4eEHsb/S/f/B2f+Y6U6/9/Azv/b36rzf62l
SPufJJynuDvnc309dR/r8ucV1/p/pKWPpTr/r7X+ey/6g9r+Yy3FyP8pjTtGQv1PD/X0vNntbHW6
NR/4GYtr/YeTWTR/JAPwe9h/9we92v57HaV8/sPF4hE2gCr+v/VC8f/hsAv8f7A9rPn/OgrkxoSp
juh1iykgDB2Wlv/d8/bpZQZirEYpqrNSMmX6zNBsgKeRb/sXy8yfEIjZQ+8uEUnRaCdhomfvJkpA
9UgRChclModPw+n0FhQUJEmYVh3ARLPFlMxoBaFWy8ZfOl59Ln2cUr7+k3iZkQc7gFSf/7r2/W+r
163X/zpKfv3jnBsrv15rP28pX/+Pcwuslv8M7fU/6Nf3v7WU/PqnO/zm6QHdZ8dfIU5evfh/6uJa
/9z+Gyw/lg+9A1St//52fv0Pa/nvWgpd3h/YVPs41SzxDTo7Tjb/HS8Teiif+OQbGS+BOzDxkOXX
w5RY0rptxJ83p+SaTIURnXAoODjc/2iZHYlXF2EajZnzjDLGwUYC/K/S3VxCuJ0saDxvhukYrhOt
1H/O4KGZFPySf8xImlJO1hLWuLU9iVZc618YZj5c+lvp/zcY9Iam/UfvRXe7tv9YS6HrmRuDyQUc
PobrH9YB+2x0oiPSHU8+YjUgLcU0uhBvj+hPaSUSz6b0FeUu7/b235x++DR6+/Fw/+C30dGbT+8p
Q4G6zcYmyTTSVX914PNGS3778Wjv8PMe/XLvePTPvT9KG0nJOCFZugmZKKQfN0vhgT7fr+UgmnQQ
/yXcdM9Pp3GWclNX5juovAEZpwMraFS8M313LHLLBH5vZ6ePDyvc1bGONMnO19mgs8QqSatpAaLf
5erknDOZ7IRdQfiOaU1gldfcqP5WmpTm7SMdiYuUez9a+zmskovc7VfCvBHUl0FnDm4UZ2DJbQTs
EqHrJDq1md+g2xQ4Rm4MGtzEggWD3WUh062At2w748Fgy6pogeAkVAZAT4+0iwRK35WRMe/W/Eo2
dJlwOrGCfolpFJGqrdhMihb5ezO0kHzd3TG/Vzmt6dvBjvapTECKn3HqMsLMyrfDlab3/fJCn1qw
VtB9b/Ehn0ArwDM/rYwWcRqBwwkMr4lZ9Ha5tQmLhaw8AeB2NFvOZE/b4G6pnuTDtkbCT9gM8Y1A
eJKFgmwH/DUG/qZvWTrAVxJ6mZkNRsr44c/oXga2uOEcRapXJIE4Vd95C8LKhnaK9z+XvYDB/Icc
3wowXwEg9pkAxFc6y1DIsQ6Dd2LbcrPIZ4zQMbgSQvATEs5LejaO42QCOa1ICTVIUsCFrRECS6oB
/ce/7j/9Ro6O1cbIkgzKIabLKZArC/SMrbd0tPKhwMTxuq+C+0z8BcluINuBJDOkJActMEgC5TLe
CTvyJ+GNQLqe3EFf55jW+kZYAOY2FeOLZstBRUUZd3LjbJzJCNZph3f0XEN2pkcS5jsLZFZEApeZ
Q/iLRpttNq2238g32xG1WsZmpGcgEc/Q8q5wb3INVnypkqzI9v/q3OjK8FLQf9miQM8vhc3+ItAl
ttARy92kJwHSs8bIfTRXz0ovI77jPJjZ7WkgDINRfaHrtYqnRnap7W+87Lb9l12rbzpMo79uoHo1
B1Q5QAqW7sZt2JLlDAtqg3UmhyDh0RlWneMPSwldNHeTi7IPW3VEl6xCMIDUsZ8/zJjzpL3Qsi3B
WcWc9/kVvL4UzEs/AukV9eeYmyVplh2MeLCMS7GbMlaOCWqbViheq690oTYxsx/P+Qe/deBt3+yL
zqqd21Y+BVABdy2ghhyjh4OyjL/LwUE3RSLPFZcvTge2zn159OSZvHkjl+j9wBiTWgRO3yhMTq6c
7BitBvxfJRASLCiQ/E4JkDjxBvk0DpKUg4IEDgZFBMYvgQFVWR9cgJdK/UlL7838KtAnS72yT+uB
eUaVq8CuR1cCPdA79paCynyjDvAjCd26C7iAW9UayJpcwPOVi2Gb9wwXaLMWQO66Qecql44abzAV
Q8Y6tKHBTvloRT1+AgqgvjVSuBaVjxLTEcMIS4fHawlIPX1k1j3LBc6qBjCHDpj5qgLwtgAsHBrA
Ml0c60DEk7vHaqIcPOtZ9znMBQofdjAbaCO5aGBixi90A5rq5z48GHBJEeZ/bLIqnJtgzh3r9MAi
2DiOS+KDOxwQZ1Gagtj8DL45t6RnKQt+ILgayH1ECiCNrlJ3R9Bf3kiMB0/uwnrRnRoBaleDeL6B
bFbtHaawKdc5+QY2ZjNgoimCyn0p3xhfolzKNVgt0KI+Yjv+Y8PImuwYuRpS6fCLO6KiVRkdkY/v
jH+FnupJ4PmhlPSiqbGnNAv0idd2vDixF7U5D1AB2fNOHxY0S8HCnsl1Oxz2h1qbEndBEeq1nUpF
+bIxoypJ+WNpL2Ut2q1+V3ZUPTZYWk5yWdp2QX1AiARS9L4YnAyvdUdwor45qKIKknFygnR1DKQy
jjYqibGoOU1u4+4bo0+1FdisVL2hA/3+w7mqjAZWu3s779z8oCg3DpwMDCfXFleZwJYwmB1hY+BV
GhAH/KmVMU9QOpsGi+5AANRoTB4VRoX+v9cdbnP933a31x/+pdsb9rZr/f9ayjP/X+E8vLJdvSdk
MY1vR0gRX7yz03mUnXvvSDqmTB4ONoGqSleg9+aSnrMDnlx8g3mJdliOQX8Wp/9ZRlkWC9ryPofz
LC2u7R1zmUOQ/8w7O2F/nXufbhckSNEy2IN884EkYu+3JF4utN+fKQy62b6jjcLKvw02r8Nkkx4X
FeF7e9/IGIMhBZvxItM0gddkfr15Ec3NReJvbPAgnqXaRzoWlj2W7vs8TJR4dELGwdDbm19HSTwH
2+bg6I9P7z8enh7+erq/v3e89y7oeYfxIbk5SqJreoO8ohjJIDsJ/A4z8mm2EL/jjA7sBPVlkCSF
8lbx8H1ML65Y65iEk89JlBE4hqdFKPDODoBdT6fnOD1k8uttMFtOs2gDAm2J2Xlqaq3LY5eORbSd
aP7oMKr4/3DQt/j/oN+v4/+vpTzTmD75FgJHNa+yHe+ZuRv4N8BImAvIhGTMBeTDm0P/4Oh6AIpH
5raRSKuSxS20cUiuScLMysHE1IdYHBA4LE1vMNYrmJvEX8kc0rTTBqLU5y6IZCI61qFcCi/bHr9P
N15TuKODo98HrxseGo1wQwr9XmvZT+gXV9tsQt46mKlD0bkZjCQKzsrcNuIMzabPPaUQukQjgynG
12aulPg/2d2d7g58V6BsyjWiKYZcBgrPdF3I4GWnC080VcU2fWKL6xsNz5K3r2IP43FhPtoc2MJG
bmpgiQGFhYEpopOGBboYjdkTKGEXMyOwBFHcekDHISQlyCPQqCLSDVRUwxQBLCtAVYMsFH++1lMv
8brUpS51qUtd6lIXo/wPYxI7sgDwAAA=

