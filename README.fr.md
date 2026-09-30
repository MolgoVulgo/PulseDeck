# PulseDeck

**La documentation anglaise fait référence.** Version anglaise : [`README.md`](README.md).

PulseDeck est une plateforme d’affichage domestique modulaire construite autour d’un **Raspberry Pi**, de **MQTT** et d’un écran **ESP32-S3 480 × 480**.

Le Raspberry Pi reste le hub central pour les accès API distants, l’orchestration de la collecte, la normalisation et la publication MQTT prête à afficher. Les métriques locales des PC/serveurs sont collectées par des instances PulseDeck Agent puis envoyées au Pi. L’ESP32 reste centré sur Wi-Fi/MQTT/NTP, le cache local, la fraîcheur des données, la navigation, LVGL 9 et les animations.

## Architecture

```text
PC gamer ──PulseDeck Agent──┐
Mini-serveur ─PulseDeck Agent─┼───────────┐
                              │           ▼
                         Raspberry Pi
                ┌──────────────────────────┐
Internet ──────►│ Weather / News           │
Agents ────────►│ métriques machines       │
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

## PulseDeck Agent V1

PulseDeck Agent est le composant de métriques local aux PC et serveurs supervisés. Il ne remplace pas le hub Raspberry Pi : l’agent collecte les métriques de sa machine et les transmet au Pi, qui reste responsable de la normalisation et de la publication MQTT destinée à l’affichage.

Le contrat des modules V1 est verrouillé ainsi :

```text
obligatoires  CPU + MEMORY + NETWORK
optionnel     GPU
```

Profils initiaux :

```text
mini-serveur  = CPU + MEMORY + NETWORK
PC gamer      = CPU + MEMORY + NETWORK + GPU
```

Métriques V1 :

- CPU : utilisation, température et puissance si disponible ;
- MEMORY : octets utilisés, octets totaux et pourcentage d’utilisation ;
- NETWORK : interface configurée, débits RX/TX et compteurs d’octets RX/TX ;
- GPU lorsqu’il est activé : utilisation, température, puissance, fréquences core/mémoire, VRAM utilisée/totale et ventilation si disponible.

Le même code agent est utilisé sur les deux machines. L’activation GPU dépend de la configuration. La configuration runtime est en YAML sous `/etc/pulsedeck-agent/agent.yml`, systemd gère le service, l’installation Arch/pacman passe par `makepkg` via un installateur propre et conscient du canal qui épingle la révision Git distante et ignore les changements du checkout local, l’installateur source standalone reste réservé aux systèmes Linux non-Arch et refuse les hôtes Arch/pacman, et la mise à jour normale utilise `pulsedeck-agent update` sur le canal installé. Le transport exact Agent → Pi et le schéma de payload réseau restent non résolus.

Voir [`agent/README.fr.md`](agent/README.fr.md) et [`agent/docs/fr/INSTALL.md`](agent/docs/fr/INSTALL.md).

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

News V1 prend en charge **NewsAPI v2** et **GNews v4**. Les deux fournisseurs sont appelés en HTTPS et PulseDeck transmet leur clé uniquement via le header HTTP :

```text
X-Api-Key: <secret>
```

Le fournisseur se choisit dans PulseDeck Admin. NewsAPI propose `top-headlines` / `everything` ; GNews propose `top-headlines` / `search`. L’interface affiche dynamiquement les filtres propres au fournisseur, puis normalise les réponses dans le même schéma MQTT retained sur `pulsedeck/v1/news/latest`. Le `content` long des fournisseurs n’est pas republié.

Les secrets restent séparés dans `/etc/pulsedeck/secrets/newsapi_api_key` et `/etc/pulsedeck/secrets/gnews_api_key` ; changer de fournisseur n’écrase pas l’autre clé.

Voir [`docs/pi/fr/NEWS.md`](docs/pi/fr/NEWS.md).

## PulseDeck Admin

Après installation, la configuration normale des services se fait depuis l’interface Web :

```text
http://<IPv4-LAN-du-Pi>:8080
```

Admin fournit actuellement :

- état Hub / MQTT / système ;
- configuration Weather, test API et hot reload ;
- sélection du fournisseur News (NewsAPI / GNews), filtres adaptés, test API et hot reload ;
- catalogue Services commun aux futurs collectors ;
- gestion du mot de passe administrateur local.

Les secrets restent masqués après stockage. Les changements Weather et News sont testés avant activation et appliqués transactionnellement.

## Installation Raspberry Pi

Aucun clone Git n’est requis sur la cible. Une cible neuve utilise une seule commande de bootstrap :

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/install.sh \
  | sudo bash
```

`install.sh` télécharge et valide uniquement le lanceur maître persistant, l’installe sous `/usr/local/sbin/pulsedeck`, initialise le cache de l’installateur, puis délègue immédiatement l’installation complète à cette commande maître. `setup_pi.sh` devient un worker interne et ne fait plus partie du flux utilisateur normal.

Les contrôles et mises à jour suivants utilisent directement :

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
├── agent/                  PulseDeck Agent local aux machines
│   ├── config/
│   ├── docs/
│   ├── packaging/arch/
│   ├── scripts/
│   ├── systemd/
│   └── src/pulsedeck_agent/
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
- PulseDeck Agent collecte uniquement les métriques locales d’une machine ; le Raspberry Pi reste le point central de normalisation et de publication MQTT.
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
5. collector News avec fournisseur NewsAPI / GNews sélectionnable.

Prochaines intégrations prévues :

- déployer et valider le premier runtime PulseDeck Agent sur le mini-serveur, puis sur le PC gamer ;
- connecter les deux agents aux collectors du Raspberry Pi et définir leurs contrats MQTT normalisés ;
- Printer ;
- écrans applicatifs ESP32, home dashboard, graphes et animations.

## Documentation

Documentation Agent : [`agent/README.fr.md`](agent/README.fr.md) et [`agent/docs/fr/INSTALL.md`](agent/docs/fr/INSTALL.md).

La documentation principale anglaise du hub se trouve sous [`docs/pi/`](docs/pi/). Les miroirs français sont sous [`docs/pi/fr/`](docs/pi/fr/).
