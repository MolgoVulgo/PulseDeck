# PulseDeck

PulseDeck est une plateforme d'affichage domestique modulaire construite autour d'un **Raspberry Pi**, de **MQTT** et d'un écran **ESP32-S3 480 × 480**.

L'objectif est de centraliser la collecte et la normalisation des données sur le Raspberry Pi, puis de distribuer des données simples et prêtes à afficher à l'ESP32 via MQTT. L'ESP32 peut ainsi se concentrer sur l'interface graphique, la navigation, le cache local et les animations LVGL.

> **Statut :** projet personnel en cours de développement. Le socle Raspberry Pi / Mosquitto / `pulsedeck-hub` est opérationnel ; le premier collector Weather est implémenté avec OpenWeather One Call 4.0 et doit maintenant être validé sur la cible.

## Architecture

```text
                         Raspberry Pi
                ┌──────────────────────────┐
Internet ──────►│ Weather collector        │
                │ News collector           │
PC ────────────►│ PC metrics collector     │
Server ────────►│ Mini-server collector    │
Printer ───────►│ Printer collector        │
                │                          │
                │    pulsedeck-hub         │
                │          │               │
                │      Mosquitto           │
                └──────────┬───────────────┘
                           │ MQTT / LAN
                           ▼
                ┌──────────────────────────┐
                │ ESP32-4848S040C_I        │
                │                          │
                │ Wi-Fi / MQTT / NTP       │
                │ cache local              │
                │ fresh / stale / offline  │
                │ LVGL 9                   │
                │ apps / widgets / graphs  │
                └──────────────────────────┘
```

Le principe central est volontairement simple :

```text
Raspberry Pi = collecte / normalisation / agrégation
MQTT         = bus de données local
ESP32-S3     = interface graphique
```

## Objectifs

PulseDeck doit permettre d'afficher plusieurs sources de données dans une interface unique :

- météo et prévisions ;
- actualités ;
- métriques du PC principal ;
- métriques d'un mini-serveur ;
- état et progression d'une imprimante ;
- état du réseau et de différents services LAN ;
- écran Home synthétique regroupant les informations importantes.

Les appels HTTP/HTTPS, clés API, protocoles spécifiques et traitements lourds restent côté Raspberry Pi. L'ESP32 reçoit des données déjà normalisées et adaptées à l'affichage.

## Matériel et stack cible

### Raspberry Pi

Plateforme actuellement utilisée :

- Raspberry Pi 3 Model B Plus Rev 1.3 ;
- Arch Linux ARM ;
- Python 3.14 ;
- Mosquitto ;
- systemd / journald.

### Écran

- ESP32-S3 ;
- carte `ESP32-4848S040C_I` ;
- écran 4 pouces 480 × 480 ;
- LVGL 9 ;
- tactile ;
- Wi-Fi ;
- MQTT ;
- NTP local.

## MQTT

MQTT est utilisé uniquement comme bus de données sur le LAN.

Configuration V1 :

- Mosquitto ;
- TCP `1883` ;
- IPv4 LAN uniquement ;
- aucune exposition directe à Internet ;
- pas d'authentification, d'ACL ou de TLS pour le réseau domestique actuel ;
- QoS 1 pour les états et snapshots ;
- QoS 0 pour les éventuels flux rapides ;
- retained messages pour les derniers états ;
- Last Will et reconnexion automatique.

Namespace principal :

```text
pulsedeck/v1/...
```

Exemples de topics :

```text
pulsedeck/v1/system/availability

pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily

pulsedeck/v1/news/latest

pulsedeck/v1/pc/gamer/dashboard
pulsedeck/v1/server/mini/dashboard

pulsedeck/v1/printer/status
pulsedeck/v1/printer/job
```

## Weather — OpenWeather One Call 4.0

Le premier collector applicatif utilise OpenWeather One Call 4.0. Le Pi interroge les endpoints `current`, `timeline/1h` et `timeline/1day`, normalise les réponses puis publie des snapshots retained QoS 1.

```text
pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily
```

Cadences par défaut : 10 minutes pour le temps actuel, 30 minutes pour les 48 heures horaires et 3 heures pour les 10 jours quotidiens. La clé API reste hors du TOML, dans `/etc/pulsedeck/secrets/openweather_api_key`.

Lors du premier déploiement Weather, `deploy_hub.sh` propose de demander la clé et le lieu. Un nom de ville peut être résolu automatiquement via le Geocoding API OpenWeather. Voir [`docs/pi/WEATHER.md`](docs/pi/WEATHER.md).

## Installation du Raspberry Pi

L'installation recommandée passe par `setup_pi.sh`. Il s'agit de l'orchestrateur complet : il prépare le socle MQTT puis installe ou met à jour `pulsedeck-hub`. Le dépôt Git n'a pas besoin d'être cloné sur le Raspberry Pi.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/setup_pi.sh \
  -o setup_pi.sh

chmod +x setup_pi.sh
./setup_pi.sh --check
sudo ./setup_pi.sh
```

Lorsqu'il est lancé seul, `setup_pi.sh` récupère automatiquement depuis GitHub les scripts spécialisés dont il a besoin. Si le dépôt est déjà présent, il utilise les copies locales. Les questions interactives sont réservées aux situations où une information ou un fichier requis ne peut pas être déterminé automatiquement.

### Scripts de déploiement

| Script | Rôle | Dépôt requis | Usage principal |
| --- | --- | --- | --- |
| `setup_pi.sh` | Orchestration complète MQTT + hub | Non | Installation recommandée |
| `bootstrap_pi.sh` | Préparation de l'hôte et installation/configuration Mosquitto | Non | Réparer ou contrôler uniquement le socle MQTT |
| `deploy_hub.sh` | Installation/mise à jour du service Python `pulsedeck-hub` | Non | Redéployer uniquement l'application |

Le mode `--check` est disponible sur les trois scripts et ne doit effectuer aucune modification.

Exemples ciblés :

```bash
# Socle MQTT uniquement
sudo ./setup_pi.sh --bootstrap-only

# Hub uniquement
sudo ./setup_pi.sh --hub-only

# Diagnostic complet
./setup_pi.sh --check --verbose
```

`bootstrap_pi.sh` configure Mosquitto sur l'IPv4 LAN détectée, active la persistence et vérifie notamment QoS 1 et retained. `deploy_hub.sh` installe le hub sous `/opt/pulsedeck`, sa configuration sous `/etc/pulsedeck` et son service systemd. Si Weather n'est pas configuré, il propose également la configuration OpenWeather One Call 4.0.

Les scripts n'exécutent pas de mise à jour globale du système (`pacman -Sy` / `pacman -Syu`).

## Organisation du dépôt

```text
PulseDeck/
├── config/                 configuration et exemples
├── docs/pi/                documentation Raspberry Pi
├── hub/                    service Python pulsedeck-hub
│   └── src/pulsedeck_hub/
│       ├── admin/
│       ├── collectors/
│       ├── health/
│       └── mqtt/
├── scripts/
│   ├── setup_pi.sh         installation complète / orchestrateur
│   ├── bootstrap_pi.sh     bootstrap système et Mosquitto
│   └── deploy_hub.sh       déploiement autonome du hub
├── systemd/                unités/templates systemd
├── PROJECT_DESCRIPTION.md  description détaillée du projet
└── PROJECT_SCHEMA.md       contrats et décisions d'architecture
```

## Principes d'architecture

- Le Raspberry Pi centralise les accès distants et la normalisation des données.
- MQTT reste un bus local simple entre le backend et les écrans.
- L'ESP32 conserve son propre NTP et un cache des dernières données valides.
- Une perte du Pi ou de MQTT ne doit pas rendre l'interface inutilisable.
- Les données peuvent être classées localement `fresh`, `stale` ou `offline`.
- Les contrats MQTT sont versionnés.
- Une nouvelle application doit pouvoir être ajoutée sans réimplémenter toute la pile réseau sur l'ESP32.
- La V1 évite volontairement les composants lourds : Kubernetes, cluster MQTT, base de données complexe ou architecture microservices.

## Roadmap

Le développement est prévu par étapes :

1. infrastructure Raspberry Pi et Mosquitto ;
2. service `pulsedeck-hub` minimal ;
3. firmware ESP32 avec Wi-Fi, NTP et MQTT ;
4. première application Weather ;
5. intégration Printer ;
6. intégration PC et mini-serveur ;
7. interface Home, widgets, graphes et animations ;
8. applications supplémentaires après stabilisation du socle.

## Documentation

Pour davantage de détails :

- [`PROJECT_DESCRIPTION.md`](PROJECT_DESCRIPTION.md) — architecture et objectifs détaillés ;
- [`PROJECT_SCHEMA.md`](PROJECT_SCHEMA.md) — contrats techniques et décisions confirmées ;
- [`docs/pi/`](docs/pi/) — installation, MQTT et exploitation du Raspberry Pi ;
- [`docs/pi/WEATHER.md`](docs/pi/WEATHER.md) — fournisseur, configuration et contrat Weather V1.

## État du projet

PulseDeck est encore en phase de construction. Le socle Pi/MQTT/hub est en place et Weather sert maintenant de collector de référence pour valider le modèle avant Printer, PC, mini-serveur et News.
