#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0007-1
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
    req=urllib.request.Request(url,headers={'Accept':'application/json','User-Agent':'PulseDeck-deploy/0.2.1'})
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
params={'lat':w['latitude'],'lon':w['longitude'],'units':'metric','lang':w.get('lang','fr'),'appid':key}
def fetch(path):
    url='https://api.openweathermap.org/data/4.0/onecall/'+path+'?'+urllib.parse.urlencode(params)
    try:
        req=urllib.request.Request(url,headers={'Accept':'application/json','User-Agent':'PulseDeck-deploy/0.2.1'})
        with urllib.request.urlopen(req,timeout=w.get('request_timeout',15)) as r: return json.loads(r.read())
    except HTTPError as e:
        print(f'{path}: HTTP {e.code}',file=sys.stderr); raise SystemExit(1)
    except (URLError,TimeoutError,ValueError,json.JSONDecodeError) as e:
        print(f'{path}: {type(e).__name__}',file=sys.stderr); raise SystemExit(1)
current=fetch('current')
hourly=fetch('timeline/1h')
data=current.get('data') if isinstance(current,dict) else None
hours=hourly.get('data') if isinstance(hourly,dict) else None
if not isinstance(data,list) or not data or not isinstance(data[0],dict): raise SystemExit(1)
if not isinstance(hours,list) or not hours or not isinstance(hours[0],dict): raise SystemExit(1)
print(f"{current.get('timezone','?')} / {data[0].get('temp','?')} C / hourly {len(hours)} records")
PY
)" || { fail "Validation OpenWeather One Call 4.0 échouée (current/timeline 1h, clé, souscription ou réseau)"; return 1; }
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
  payload=""
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    payload="$(timeout 3s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t pulsedeck/v1/weather/hourly -C 1 2>/dev/null || true)"
    if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);h=d.get("hours");raise SystemExit(0 if d.get("schema")==1 and isinstance(h,list) and len(h)>0 else 1)' "$payload" 2>/dev/null; then
      ok "Weather hourly retained présent"
      break
    fi
    sleep 2
  done
  if ! [[ -n "$payload" ]] || ! python -c 'import json,sys;d=json.loads(sys.argv[1]);h=d.get("hours");raise SystemExit(0 if isinstance(h,list) and len(h)>0 else 1)' "$payload" 2>/dev/null; then
    warn "Weather hourly retained non observé"
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

info "PulseDeck standalone hub deployer patch_0007-1"
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
qUtd7lL+B54hcuMA8AAA
