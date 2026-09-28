# PulseDeck

**La documentation anglaise fait référence.** Version anglaise : [`README.md`](README.md).

PulseDeck est une plateforme d’affichage domestique modulaire construite autour d’un **Raspberry Pi**, de **MQTT** et d’un écran **ESP32-S3 480 × 480**.

Le Raspberry Pi centralise les accès API distants, la collecte et la normalisation. Il publie via MQTT des snapshots simples, versionnés et prêts à afficher. L’ESP32 reste centré sur Wi-Fi/MQTT/NTP, le cache local, la fraîcheur des données, la navigation, LVGL 9 et les animations.

## Architecture

```text
                         Raspberry Pi
                ┌──────────────────────────┐
Internet ──────►│ Weather / News           │
PC ────────────►│ métriques PC             │
Server ────────►│ métriques mini-serveur   │
Printer ───────►│ état imprimante          │
                │                          │
                │    pulsedeck-hub         │
                │          │               │
                │      Mosquitto           │
                └──────────┬───────────────┘
                           │ MQTT / LAN
                           ▼
                ┌──────────────────────────┐
                │ ESP32-4848S040C_I        │
                │ Wi-Fi / MQTT / NTP       │
                │ cache local              │
                │ fresh / stale / offline  │
                │ LVGL 9                   │
                └──────────────────────────┘
```

```text
Raspberry Pi = collecte / normalisation / agrégation
MQTT         = bus de données local
ESP32-S3     = interface utilisateur
```

## Stack Raspberry Pi actuelle

- Raspberry Pi 3 Model B Plus comme cible de référence ;
- Arch Linux ARM / `armv7l` ;
- Python 3.14 ;
- Mosquitto natif ;
- un processus Python `pulsedeck-hub` ;
- Web Admin FastAPI/Uvicorn dans le hub ;
- systemd / journald ;
- aucun conteneur ni base de données nécessaire en V1.

## MQTT

PulseDeck V1 utilise Mosquitto comme bus de données sur le LAN de confiance :

- TCP `1883` ;
- listener IPv4 LAN uniquement ;
- aucune exposition directe à Internet ;
- QoS 1 pour états/snapshots ;
- QoS 0 pour les éventuels flux rapides ;
- derniers snapshots retained ;
- Last Will et reconnexion automatique.

Namespace principal :

```text
pulsedeck/v1/...
```

Topics applicatifs actuellement implémentés :

```text
pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily

pulsedeck/v1/news/availability
pulsedeck/v1/news/latest
```

## Weather

Weather V1 utilise OpenWeather One Call 4.0. Le hub récupère `current`, `timeline/1h` et `timeline/1day`, normalise les réponses et publie des snapshots retained QoS 1.

Cadences par défaut :

```text
current  10 min
hourly   30 min, horizon 48 h
daily     3 h,   horizon 10 jours
```

La clé OpenWeather est séparée du TOML dans `/etc/pulsedeck/secrets/openweather_api_key` et se gère depuis PulseDeck Admin.

Voir [`docs/pi/fr/WEATHER.md`](docs/pi/fr/WEATHER.md).

## News

News V1 utilise **NewsAPI v2** en HTTPS avec authentification fournisseur dans l’en-tête HTTP :

```text
X-Api-Key: <secret>
```

La clé n’est jamais ajoutée à la query string. PulseDeck prend en charge `top-headlines` et `everything`, normalise les métadonnées d’articles, exclut volontairement le champ fournisseur `content`, puis publie un snapshot retained compact sur `pulsedeck/v1/news/latest`.

Le secret NewsAPI est stocké dans `/etc/pulsedeck/secrets/newsapi_api_key` et se configure depuis PulseDeck Admin.

Voir [`docs/pi/fr/NEWS.md`](docs/pi/fr/NEWS.md).

## PulseDeck Admin

Après installation, la configuration normale des services se fait depuis l’interface Web :

```text
http://<IPv4-LAN-du-Pi>:8080
```

Admin fournit actuellement :

- état Hub / MQTT / système ;
- configuration Weather, test API et hot reload ;
- configuration News, test NewsAPI et hot reload ;
- catalogue Services commun aux futurs collectors ;
- gestion du mot de passe administrateur local.

Les secrets restent masqués après stockage. Les changements Weather et News sont testés avant activation et appliqués transactionnellement.

## Installation Raspberry Pi

Aucun clone Git n’est requis sur la cible. Une cible neuve nécessite un seul téléchargement initial :

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/setup_pi.sh \
  -o setup_pi.sh

chmod +x setup_pi.sh
./setup_pi.sh --check
sudo ./setup_pi.sh
```

Cette première application installe la commande maître persistante `/usr/local/sbin/pulsedeck`. Les contrôles et mises à jour suivants utilisent directement :

```bash
pulsedeck --check
sudo pulsedeck
sudo pulsedeck --hub-only
```

Le lanceur maître rafraîchit `pulsedeck.sh`, `setup_pi.sh`, `bootstrap_pi.sh` et `deploy_hub.sh` depuis la référence Git sélectionnée, valide leur syntaxe shell et ne remplace que les copies de cache modifiées avant d’exécuter le worker `setup_pi.sh` rafraîchi. Le retéléchargement manuel de `setup_pi.sh` ne fait donc plus partie du flux normal de mise à jour.

L’installateur gère le socle technique. Les clés, filtres et réglages fonctionnels des collectors appartiennent à PulseDeck Admin. Les scripts n’exécutent jamais de mise à jour globale Arch Linux (`pacman -Sy` / `pacman -Syu`).

## Organisation du dépôt

```text
PulseDeck/
├── config/
├── docs/pi/                documentation opérationnelle anglaise
│   └── fr/                 miroirs français
├── hub/
│   └── src/pulsedeck_hub/
│       ├── admin/
│       ├── collectors/
│       ├── health/
│       └── mqtt/
├── scripts/
├── systemd/
├── README.fr.md
├── PROJECT_DESCRIPTION.md
└── PROJECT_SCHEMA.md
```

## Principes d’architecture

- Les API distantes, HTTPS, identifiants et protocoles fournisseur restent sur le Raspberry Pi.
- MQTT reste un bus local simple entre backend et écran.
- L’ESP32 conserve son NTP autonome, son UI et le cache des dernières données valides.
- Une panne Pi/MQTT ne doit pas rendre l’interface locale inutilisable.
- Les payloads MQTT sont versionnés, normalisés et timestampés.
- La V1 évite volontairement Kubernetes, cluster MQTT, base lourde et flotte de microservices.

## Roadmap

Socle déjà réalisé :

1. infrastructure Raspberry Pi / Mosquitto ;
2. runtime minimal `pulsedeck-hub` ;
3. collector Weather ;
4. Web Admin ;
5. collector News / NewsAPI.

Prochaines intégrations prévues :

- PC gamer ;
- Printer ;
- mini-serveur ;
- écrans applicatifs ESP32, home dashboard, graphes et animations.

## Documentation

La documentation principale anglaise se trouve sous [`docs/pi/`](docs/pi/). Les miroirs français sont sous [`docs/pi/fr/`](docs/pi/fr/).
