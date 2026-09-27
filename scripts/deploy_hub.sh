#!/usr/bin/env bash
# PulseDeck Hub standalone deployer — patch_0003
# Self-contained: no PulseDeck repository checkout is required.

set -u
set -o pipefail

CHECK_ONLY=0
VERBOSE=0
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
Usage: ./deploy_hub.sh [--check] [--verbose] [--help]

  --check     Validate host/runtime state without changing anything.
  --verbose   Print extra diagnostic values.
  --help      Show this help.

Default mode installs/updates the PulseDeck Hub into /opt/pulsedeck,
creates /etc/pulsedeck/pulsedeck.toml on first install, and manages the
pulsedeck-hub systemd service. No Git checkout is required.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --verbose) VERBOSE=1 ;;
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

install_app() (
  local tmp old
  tmp="$(mktemp -d)" || { fail "mktemp échoué"; return 1; }
  trap 'rm -rf "$tmp"' EXIT
  if ! extract_payload "$tmp"; then
    fail "Extraction du payload embarqué échouée"
    return 1
  fi

  install -d -m 0755 "$APP_ROOT" || { fail "Création $APP_ROOT échouée"; return 1; }
  if [[ -d "$APP_DIR" && ! -f "$APP_DIR/.pulsedeck-managed" ]]; then
    fail "$APP_DIR existe sans marqueur PulseDeck; remplacement refusé"
    return 1
  fi
  old="${APP_DIR}.old.$$"
  if [[ -d "$APP_DIR" ]]; then mv "$APP_DIR" "$old" || { fail "Sauvegarde temporaire $APP_DIR échouée"; return 1; }; fi
  if cp -a "$tmp/hub" "$APP_DIR"; then
    : > "$APP_DIR/.pulsedeck-managed"
    rm -rf "$old"
    ok "Sources hub installées dans $APP_DIR"
  else
    [[ -d "$old" ]] && mv "$old" "$APP_DIR"
    fail "Installation des sources hub échouée"
    return 1
  fi

  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    if python -m venv "$VENV_DIR"; then ok "venv créé: $VENV_DIR"; else fail "Création venv échouée"; return 1; fi
  else
    ok "venv existant: $VENV_DIR"
  fi

  info "Installation des dépendances Python du hub dans le venv (pas de mise à jour système)"
  if "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check --no-cache-dir "$APP_DIR"; then
    ok "pulsedeck-hub installé dans le venv"
  else
    fail "Installation Python du hub échouée"
    return 1
  fi

  install -d -m 0755 "$CONFIG_DIR" || { fail "Création $CONFIG_DIR échouée"; return 1; }
  if [[ -e "$CONFIG_FILE" ]]; then
    ok "Configuration existante conservée: $CONFIG_FILE"
  else
    sed "s/@LAN_IPV4@/$LAN_IPV4/g" "$tmp/pulsedeck.toml.in" > "$CONFIG_FILE" || { fail "Création config échouée"; return 1; }
    chmod 0644 "$CONFIG_FILE"
    ok "Configuration initiale créée: $CONFIG_FILE"
  fi

  install -d -m 0750 -o "$RUN_USER" -g "$RUN_GROUP" "$STATE_DIR" || { fail "Création $STATE_DIR échouée"; return 1; }

  if [[ -e "$UNIT_FILE" ]] && ! grep -q '^# Managed by PulseDeck deploy_hub.sh' "$UNIT_FILE"; then
    fail "$UNIT_FILE existe sans marqueur PulseDeck; remplacement refusé"
    return 1
  fi
  install -m 0644 "$tmp/pulsedeck-hub.service" "$UNIT_FILE" || { fail "Installation unité systemd échouée"; return 1; }
  ok "Unité systemd installée"

  systemctl daemon-reload || { fail "systemctl daemon-reload échoué"; return 1; }
  systemctl enable --now "$SERVICE" || { fail "Activation/démarrage $SERVICE échoué"; return 1; }
  ok "$SERVICE activé et démarré"
)

check_runtime() {
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    ok "$SERVICE actif"
  else
    warn "$SERVICE inactif"
    return 1
  fi
  if [[ -x "$VENV_DIR/bin/pulsedeck-hub" ]]; then ok "Entrée runtime présente"; else warn "Entrée runtime absente"; fi
  if [[ -r "$CONFIG_FILE" ]]; then ok "Configuration runtime présente"; else warn "Configuration runtime absente"; fi

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

info "PulseDeck standalone hub deployer patch_0003"
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
H4sIAMkquWoC/+09a3PbOJL5zF+B5VRqpS2ZeliPRLdMJZs4E1dlHJ/tZO7K5eJQFCRzQpEMAdrW
5fLfrxsAn6JleyZ29sbAB4kEGo1GA+huNB60ulb35aF79Y66c5o8uZfQk+G6/15vd1g8Y3y/N+gP
npCrJw8QUsbdBIp/8jjD4BlZcX9F7f7keW80APY/t3r98XjYHxpPdPjLh/N01r3vMqBTDSajUXnc
9yejfmXM90eD0XgwGO32Ib4Pb5MnZPSQ4z+JIr4NLnJ9h527CZ3/pdrf0vJfy38t/x+1/I/XcRL9
Tj1u8WgV3M/4Hw+H18r/0Whck//D4RDkf+8hx/8jlf+ns9QP5jtszThdnRkJ/ZL6CWXEJqcmozyN
eRQF7IU9GZlnhoSdud5nGs4BpARhiTRnRblrGsap6lBnRuiuKELGacDonHqfd6DHmcYFTZgfhZjS
s/pWzzTmlHmJH3MVe4jwbwCeHLksntEkWZNDn8xd7hKBIaN0J17zc5nnhb1r9YeIKgb6aOj5siIG
gWDG7nm0s/rC+Qt7YPU7/9w1O8ZZQaoli2dnRoXUCu0ORFgr1w+n+IP1xLpbJS7EwBt3SZm18MP5
mXF5ThMqeZl4wECt/7X+1/pfh38v/Q+y6V7ngHef/w12+2M9/9PyX8v/HyT/nz0f7Wr5/4jkf8XG
7X738X9H+T/q7+5q+a/lv5b/P0j+T3qTiZb/j1b+O44f+txxrHj9AP6/3mhYk/+TwbCv/X8PEUyz
5GpD9xZEGIbjKAed45RcdHq0/PWC1v9a/zfp/+FQ+/8er/73onDhL7+P9r9R/w8no0FN/48n457W
/w+k/4/SECUAkY2eJq5Yg1tECeHnlDRYB4skWhHHWaQ8TShYCP4qjhJO3DCMuMjMFAyu1nmByxhl
GVAeJSFil58H/ixLPYRXQz3jWjQkGYbxZu/tq4/vT5zXHw7e7v/sHL46eQdWCcK2zC7lpc5bPIml
bLMNuV/mRbagyP+hoX2SpLRDWBBxJp7bhkgmv/znyclrwYSpWDI8jxifEsYT8YZETYkfcii7/+zZ
rojE5U0Wux4VcJXFwu5F3xQwXuDTkDv+fBNGLoYi0GdKYzfwL2hWxG5PxCcUmiWkHndWfujMaeCu
cyLqAO5VFQBQCJCXcRLFNOFr8TanC+JeuH7gzvzA52uHR7HvtRgNFm2y8wJplNWX2KGNoTOYXzHd
yqtrJQDmx62/d//e/taVq8fdMlbzTpx/l87KjMdV2mmpOQAXUu3EEfM58AhmJ7x14QYpcCua4ept
R7SEYHCH/KNDgBf+Kl1JTvwvOYhCXIbFP1FHiJUl+QviMz8EGRB6VKLskFkUBW0C/R/6c0MyZBap
4pX80ya9Er9cn1HyCVP2kiRKWsA5pOwbWYGgITNKXJLVAhHRJU2glypSFNVQpihaUO2Gc1XSi7xW
dygOyPuqsn1TBak2FUgVZ4PInTty/LdwSE7F6AKONQw9wcBag136AI0ZLehoYctMZmabuIycA/UB
LdN7CUjVyLaw1JYEaRt5wzsSCH6tJeUtE+MKFtWaJMvQIXPf4+0tnDFXPoN8S3KKec5q0o5BH4J/
U9GBIx9oyLBLQjDyWkIwsYPdL+84GGPJUbKdLijEEgUWXSSMwh26ivkaMQLRGV35+NsgLk8xOzUZ
1K4KoY2ceUolp5BM11U2L6xa40I6yGqbXfPmmhdV2lr9ZkJy2quE5NG35n/BnpsbwVssgYmFdGrl
yLEV7XK7d/Ik1B52VYBVmwEBoAVQs7ShIQRVKk6NX3s8Gu2OSjhz1tlNnC/g8srZG4wpgHIFtJXK
HArI2u3lhBbRJYwNqmsr7gZ4ZEheSFN6c3GZIrxtcRl8tVJNAKq8vD9CX2iiC2R1LSXXzTf1xCZs
JWF+PWVl2Z6LZ1FnG2hpG3r+r+f/t57/6/XfRz3/D6LlEjSeI3Y2/mk3wE3+/93xqDr/H/R2RyM9
/3+g+f972dhENLaY98v53Lz7ewTKxA3mhF5RL0UDWToA1Axd9RI1h8gMauqo+FZAL2iQTUZVpLV/
8PaDmELg7EZqwyxp5jLfq9tUAoktfgtdD0SuXG6bT1su81B8tRl5KstDU0i85Q9gGjF3Cc9mprz1
sNf6X+v/bfr/+WAw0MPk0ep/PN7wvbz/N+r/wWhQP/8zHoJI0Pr/YfR/xcNPaMiTNYkj0Nq39/Zn
cckydhNG6wbCTa5+5i/BzMgd/+cJKCNhWIiMlrQssowNLslO2YGpMlVM2Czvho2igEs+oAwUptDC
xSMiwcR5/+HnkhWzpBzNJpq0HAcNDcdp505q5EDSEjZOxhDrVbJMV4DoUCRKs0cCAtJroFpxEi3t
RpeczGq587njqjyFxWTu7Mh6moXBxNcxtZHlRRQQ66YBt5v4WXi0aBDbC/Pkwy/vax5TbE7SUkim
5GsDmm9ts+wuUb4JSbviFgqaVtUlDxXCU1s5Hy3xgPVkLeXL3LA0ZTx03MK9ojqNXfFtIxLVnWQW
euXRmJPWh2Phg+mU/DHCgQ3pBUroAhaVrprXFV6IyCl5ChYm5mjXl08G0nHIeBQ7YKMKezjv5dYe
xrSUcxGZgkfbKOMOwrdwbKSrDlkkaM/mhjMhP5Ew+uJOyauDA5CnFSL9cBG1zOPzlM+jyzDDR+dk
tlZjTdIqcRfkFgTimbaMJJnDkn8t9Xa8//PJ3tEvnQqx7a3w+wcndfDC6a8Gn10ddy21EI0g7Tqw
hZKbN7V9qR6Xrp+BLHwgJCiBVXEBryv9tAdd1IfxrMY3sW1iOg52WMcxJRLpwjsWs6W9KyhIduf/
TxMMbf9r+7/J/7f7XO//fcT2P0jG7vcc/3c8/zHuD3r6/IeW/1r+a/mvww+S/9/tEMiN5z+Gw/r6
Dzxp/88D+X9wugXzJzdkwvGBC0C5S0i4gPQo+euGfw/9v7up//ta/z+I/p806//xMz3sH7n+V56x
P78MdIP+n4wHu/Xzn5PRWOv/B9L/h3jUk3F0vwpTQO0t/A6HQGrLQBvrO1kEyJ8cGK9pq6zHuEw4
arPFoNpqUOmQgEyP3TV6/PMDJ5WjDirxlss5+dmEwiE9zZ30mXUsDk501HJD+dBCbZOL8EvjGYp8
YUItV1USGWXi2K1wbVPcrI0bV5FBFv6gb7mODNtKQG6uKFRBMw+7YK7yr+cgYsnEDQK83M9xYz87
AGxLaJXy6nD/k4y3Pu0dHe9/OBh0qiiKrcbSc1/s0K7AxUnEIy8KJHpk2gWM/Dou6gInJEfk0ZE8
vbFuFjBOMQSqKRKcIuq6HHOfNWQqYm8oyVlA/2ooTsQ35i1274qdu7hCWW2HYru0YmLDnuAqq4od
z5s5sqSbmEdDdxbIJTUYB5sjw8xHptlWKzcYfiKvyHuXcfKrHwTQhXD8k89hdCkEhxQPpMRj7MbQ
u1exRX7j7DeESijIGVrCiNQnMIQvz2ko0AjclyAJ4oTGKIPFsRjI73z2w/lvUP/PlAGkywm9igPf
87mV47vEzHajIKjy3YwWi8APqVllbm1M2k0DtZoDxiGDLmsWkhTYyngNb86JW2DMYUWFbRPr5HhQ
DkCaN7WsAN7oZaqnbB4Fq41UySkbkVRTvkTM7tcrzl1/c6wWQrMYH5ncFCR2SMpogsfFOmQRuEvW
UTwE6DntEHWAzafsFiug/qKc2fKZGIrQDacVWkuruXW1Bx0S6JmrFd0SsnatY5QlsIXyKmm16wxJ
k/Aama0WWWucvmVXDf90Ty1KxvViVEjK4Etngc/OW411vUuXUf9/tNeU2hMJtBKP/E1pL2wwZ+/o
yDn++Pr13vHxtS37UQg1wiOiakUk4yosnpLEs0VTq3Lam6vpVe6XOwwII0D/lE2fsv+ooBUor2Wi
ODB2bSqaLp0/1ADNo00MgWuG3C2G1A09Hbl06SYhbsXYGEwu53iKiiAFdA4sSnm0AgvRw3ZP1vCL
q+aMuB4XB4iq9Bea41qBUYA4f1p23FDRO4iWKj8KGqG7pCEoKfEYrLfJGApG9yZiubljA2uZcXJj
RH6it2qEljaIIBju/JZNJu1DuTGk1NlyC65ZuWSsd9k69Fr30t3z02U3KbogimIn2xVS4gZuo2lm
BjRorcmhTYVYnjaJtFvJ5i2mxB8zJ8omxTJxPdBOoM/V7p5aCVX1owR7mUeN0v2uEv5GKX+NpL9W
2m+SXtnQU66P2NLjgMXoZFVB4yhKuT2welUcaneXuuBA7OraxLk5WFXbVZoaJFoazMXp0pm6KiFZ
4Y4qYbuSvDWaO2ZJim3tuWIPkl7/1eu/P3r9d/Ksr8//PXL/b+ZJu+/13/6wP944/9fT/t+H8v8e
r9wgQJsRZ0q5+xQnwLhfGLrDjjhYJ61EYQywO7uAfwfjperuNTbuoakYU0AOV/e5iPd/yL+anSQO
F3aMwkCSV+xULnyRybkDpeFKmBqEcLHkd/WIbcRgZFXvxvEXkkJ5IUVIvuYT8sL0+7b1npY0ZGmM
/EBnVtnQUDX/Kv6/5Rv+BW+m4pqTU3HLjbz45gxo/Fps/WfeOUynzCkpGV6mwGROJeZSPGfmdMO/
jFXLWYE30QhG4VQkBxVJ7QoiwTPAVmVimYZqw6mCa7EK5zejMtea1j0kp6ZMMLHy8rG8cRv7mjVP
VzFrZbYp9JvYTVweJcxumR1spanZhmjgv/OZrrPbiPT6v7b/tP2H6//9vt4A8MjtP6Xq7339vz8Z
jDbW/yfa/nso+6+w68RxP5qwhnX/T/3S9V63tv6EkSfvF6zelAiqN10s/KupvLerbFoVVw7Wb7WS
lw1+lTmtoBRpqqLkxRVO2Z5q3XBFY2PhNZLBXGi64hD3CJx8ONx/7Rx/fPt2/7/2jnNjzLykLq5s
VkgBoyeLryLqVPN4aZKg0VkCz6JqkOdRmgQVvCqmBjeHwipgMkJBhfSSbRCKkY1UCugALEnGczj1
qiBiz1kC6zYrH3tdkdCIN881d9n5LHKTeSVLEavgGU0uAHrlh/5GQTKti2mNZZXzVoorZ9woMU7w
xsaGasn45lqpPGh7p6wMrWJqcL9HszIQvtYg+Hm6moVQUhmuiOwY3+6iuLX9p+2/TfvvWW840uc/
HkOo3C5gofjzPXoP43+b/dfb+P7vqDfW9t+DhJ/IL27oLqWvrzD35jQOorX43i07N04/hj4/M94U
n+i1C9B36cx4tQAlZIeUX0bJ5x3pCrOAr0vKySpiX1Kf8yjrXcavbshZM7RxpD7ra29mM06P5dOZ
cYLXWTCwOANqfIR0O+/Gxs9JlMal91+hDD9cvgGkHo+Std29cJNu4M+KKY+xd0U9sRhud6OYl64T
v6DhRXfmh93qN4GzCzbI1tvHoS7Cr2VH4Y7aJpBFHVPPHhl74YWfRCHe3mEf/vfJuw8HHw/+BZbk
3tHeG7tvHEQH9PIw8S/8gC6BIzxJqYHvYGydrOLsPeJQMXkHgY0mscezyHcRyHUBdQTa/dfE5xSv
AGFNLDBO9/FS3SA4E81D5/9a26s04P4ObrTIWkfLS+3/uw/7T5//+WH2X+P5n8nz0XM92B+V/SdU
luWH9zT+t53/HY/r9t9wMNTff3lg+w+Ps/huULvmS+0x32odig8qGOqbCebL968OnP3DT8OXpiE8
gupzKeVvF9S+klL+OEH94yj55j/5QZOm69HxUygNBx7UF1BO3TmAnhnyfAMWsXChBEjwoiAQRiGz
lF9sE6oMhK6u7RCZD2s7lHA7SU/TDeikd2cTSMstHXTQQQcddNBBBx100EEHHXTQ4fbh/wAFhA0+
AKAAAA==
