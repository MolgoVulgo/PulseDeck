#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0007-2
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
api_root='https://api.openweathermap.org/data/4.0/onecall'
api_host='api.openweathermap.org'
params={'lat':w['latitude'],'lon':w['longitude'],'units':'metric','lang':w.get('lang','fr'),'appid':key}

def fetch_url(url,label):
    parsed=urllib.parse.urlsplit(url)
    if parsed.scheme not in {'http','https'} or parsed.hostname != api_host or not parsed.path.startswith('/data/4.0/onecall/'):
        print(f'{label}: unsafe provider URL',file=sys.stderr); raise SystemExit(1)
    safe=urllib.parse.urlunsplit(('https',api_host,parsed.path,parsed.query,''))
    try:
        req=urllib.request.Request(safe,headers={'Accept':'application/json','User-Agent':'PulseDeck-deploy/0.2.2'})
        with urllib.request.urlopen(req,timeout=w.get('request_timeout',15)) as r: raw=json.loads(r.read())
    except HTTPError as e:
        print(f'{label}: HTTP {e.code}',file=sys.stderr); raise SystemExit(1)
    except (URLError,TimeoutError,ValueError,json.JSONDecodeError) as e:
        print(f'{label}: {type(e).__name__}',file=sys.stderr); raise SystemExit(1)
    if not isinstance(raw,dict):
        print(f'{label}: invalid response',file=sys.stderr); raise SystemExit(1)
    return raw

def fetch(path):
    return fetch_url(api_root+'/'+path+'?'+urllib.parse.urlencode(params),path)

current=fetch('current')
page=fetch('timeline/1h')
data=current.get('data')
if not isinstance(data,list) or not data or not isinstance(data[0],dict): raise SystemExit(1)

hours=[]; seen=set(); pages=0
while True:
    pages += 1
    chunk=page.get('data')
    if not isinstance(chunk,list):
        print(f'timeline/1h page {pages}: invalid data',file=sys.stderr); raise SystemExit(1)
    for item in chunk:
        if not isinstance(item,dict): continue
        stamp=item.get('dt')
        if not isinstance(stamp,int) or stamp in seen: continue
        seen.add(stamp); hours.append(item)
    if len(hours) >= 48: break
    next_url=page.get('next')
    if not isinstance(next_url,str) or not next_url:
        break
    if pages >= 6:
        print('timeline/1h: pagination limit reached',file=sys.stderr); raise SystemExit(1)
    page=fetch_url(next_url,f'timeline/1h page {pages+1}')

if len(hours) < 48:
    print(f'timeline/1h: only {len(hours)}/48 records',file=sys.stderr); raise SystemExit(1)
print(f"{current.get('timezone','?')} / {data[0].get('temp','?')} C / hourly 48 records / {pages} pages")
PY
)" || { fail "Validation OpenWeather One Call 4.0 échouée (current/timeline 1h paginée, clé, souscription ou réseau)"; return 1; }
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
  local state enabled lat lon name key_file expected_hourly
  weather_enabled || { warn "Weather collector désactivé"; return 0; }
  state="$(read_weather_state 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    IFS=$'\t' read -r enabled lat lon name key_file <<<"$state"
    [[ -n "$key_file" ]] && WEATHER_KEY_FILE="$key_file"
  fi
  expected_hourly="$(python - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import sys,tomllib
with open(sys.argv[1],'rb') as f: c=tomllib.load(f)
print(c.get('collectors',{}).get('weather',{}).get('hourly_hours',48))
PY
)"
  [[ "$expected_hourly" =~ ^[0-9]+$ ]] || expected_hourly=48
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
    if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);h=d.get("hours");raise SystemExit(0 if d.get("schema")==1 and isinstance(h,list) and len(h)==int(sys.argv[2]) else 1)' "$payload" "$expected_hourly" 2>/dev/null; then
      ok "Weather hourly retained présent: ${expected_hourly} records"
      break
    fi
    sleep 2
  done
  if ! [[ -n "$payload" ]] || ! python -c 'import json,sys;d=json.loads(sys.argv[1]);h=d.get("hours");raise SystemExit(0 if isinstance(h,list) and len(h)==int(sys.argv[2]) else 1)' "$payload" "$expected_hourly" 2>/dev/null; then
    warn "Weather hourly retained non observé avec ${expected_hourly} records"
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
    local payload attempt
    payload=""
    for attempt in 1 2 3 4 5; do
      payload="$(timeout 3s mosquitto_sub -h "$LAN_IPV4" -p 1883 -q 1 -t pulsedeck/v1/system/availability -C 1 2>/dev/null || true)"
      if [[ -n "$payload" ]] && python -c 'import json,sys;d=json.loads(sys.argv[1]);raise SystemExit(0 if d.get("schema")==1 and d.get("state")=="online" else 1)' "$payload" 2>/dev/null; then
        ok "Availability MQTT retained = online"
        verbose "$payload"
        break
      fi
      sleep 2
    done
    if ! [[ -n "$payload" ]] || ! python -c 'import json,sys;d=json.loads(sys.argv[1]);raise SystemExit(0 if d.get("schema")==1 and d.get("state")=="online" else 1)' "$payload" 2>/dev/null; then
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

info "PulseDeck standalone hub deployer patch_0007-2"
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
jQDwAAA=
