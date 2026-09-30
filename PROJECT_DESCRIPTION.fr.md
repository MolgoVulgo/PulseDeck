# Nouveau projet — Hub Raspberry Pi + MQTT + ESP32-4848S040C_I

**La documentation anglaise fait référence.** Version anglaise : [`PROJECT_DESCRIPTION.md`](PROJECT_DESCRIPTION.md).

## 1. Clôture PulseMon

PulseMon reste sur son architecture actuelle et n'est pas refondu en plateforme multi-applications.

État de clôture :
- firmware ESP32-S3 fonctionnel ;
- NTP autonome ;
- séquence réseau validée ;
- Météo, News, Printer puis backend PC initialisés dans cet ordre ;
- gestion backend PC `UNKNOWN / ONLINE / SUSPECT / OFFLINE` ;
- délai avant OFFLINE pour absorber les ralentissements ponctuels ;
- Main/GPU verrouillés lorsque le backend PC est indisponible ;
- retour automatique lorsque le backend redevient disponible ;
- scénarios matériels complémentaires réalisés : coupure courte, navigation offline et boot avec PC éteint.

PulseMon devient donc la base stable existante. Les expérimentations d'architecture, LVGL 9 et applications enrichies seront réalisées dans un nouveau projet distinct.

---

## 2. Objectif du nouveau projet

Créer une nouvelle plateforme d'affichage domestique extensible autour de trois briques :

```text
Raspberry Pi = collecte / normalisation / agrégation
MQTT         = bus de données
ESP32-S3     = interface graphique
```

Matériel écran ciblé : `ESP32-4848S040C_I`, écran 4 pouces 480 × 480, avec une UI conçue dès l'origine pour LVGL 9.

Objectifs principaux :
- plusieurs applications ;
- données provenant de plusieurs sources ;
- UI riche ;
- animations ;
- graphes ;
- navigation fluide ;
- faible complexité réseau côté ESP32 ;
- ajout d'une nouvelle application sans réimplémenter HTTP/TLS/API sur l'ESP32.

---

## 3. Architecture cible

```text
PC gamer ──PulseDeck Agent──┐
Mini-serveur ─PulseDeck Agent─┼───────────┐
                              │           ▼
                        Raspberry Pi
                ┌──────────────────────────┐
Internet ──────►│ Weather collector        │
                │ News collector           │
Agents ────────►│ Métriques machines       │
Printer ───────►│ Printer collector/bridge │
LAN ───────────►│ Network collectors       │
                │                          │
                │      service hub         │
                │          │               │
                │      Mosquitto           │
                └──────────┬───────────────┘
                           │
                           │ MQTT
                           ▼
                ┌──────────────────────────┐
                │ ESP32-4848S040C_I        │
                │                          │
                │ Wi-Fi                    │
                │ MQTT                     │
                │ NTP local                │
                │ cache local              │
                │ fresh/stale/offline      │
                │ LVGL 9                   │
                │ apps / widgets / graphs  │
                │ animations               │
                └──────────────────────────┘
```

Principe fondamental : le Pi reste le collecteur/normaliseur central et le producteur MQTT ; les agents locaux ne collectent que les métriques de leur machine. L'ESP32 affiche, anime, met en cache et gère l'interaction utilisateur.


### PulseDeck Agent V1

Les métriques locales des PC/serveurs sont collectées par un même code PulseDeck Agent. L’agent ne remplace pas le hub Raspberry Pi : il collecte les métriques de sa machine et les transmet au Pi ; le Pi reste responsable de l’orchestration des sources, de la normalisation et de la publication MQTT destinée à l’affichage.

Modules V1 verrouillés :

```text
obligatoires  CPU + MEMORY + NETWORK
optionnel     GPU
```

Profils de déploiement initiaux :

```text
mini-serveur  = CPU + MEMORY + NETWORK
PC gamer      = CPU + MEMORY + NETWORK + GPU
```

Périmètre des métriques V1 verrouillé :
- CPU : utilisation, température et puissance si disponible ;
- MEMORY : octets utilisés, octets totaux et pourcentage d’utilisation ;
- NETWORK : interface configurée, débits RX/TX et compteurs d’octets RX/TX ;
- GPU lorsqu’il est activé : utilisation, température, puissance, fréquence core, fréquence mémoire, VRAM utilisée/totale et ventilation si disponible.

Le collector réseau cible l’interface sélectionnée par la configuration YAML afin de ne pas agréger implicitement les interfaces de conteneurs/bridges ; `auto` résout si possible l’interface portant la route par défaut. L’activation GPU dépend de la configuration. La configuration Agent est en YAML sous `/etc/pulsedeck-agent/agent.yml`, systemd supervise le runtime, l’installation Arch/pacman utilise `makepkg` depuis un checkout temporaire propre du canal distant sélectionné et épinglé à une révision Git précise ; l’installateur Arch authentifie sudo une seule fois, construit sans déléguer l’installation à makepkg, puis installe explicitement et sans interaction le paquet produit avec pacman. L’installateur standalone utilise les mêmes sources `agent/` mais est réservé aux systèmes Linux non-Arch et refuse les hôtes Arch/pacman, et `pulsedeck-agent update` est la commande de mise à jour commune sur le même canal. À partir de `patch_0021`, le transport Agent → Pi V1 est HTTP en lecture seule sur le LAN de confiance. L’Agent expose `GET /v1/snapshot` sur une adresse d’écoute et un port configurables (port `8765` par défaut) ; le Pi interroge un host/IP et un port configurables. Aucune IP de machine supervisée n’est codée en dur. L’endpoint HTTP est sans authentification dans le périmètre LAN de confiance V1 actuel et ne doit pas être exposé directement à Internet.

La première cible de déploiement de l’Agent est le mini-serveur avec CPU + MEMORY + NETWORK. Le PC gamer utilise le même agent avec GPU activé. `agent-002` maintient un snapshot diagnostique local sous `/var/lib/pulsedeck-agent/snapshot.json`. `patch_0021` ne lit pas ce fichier à distance : il définit une enveloppe réseau HTTP distincte (`schema=1`, `protocol=pulsedeck-agent-http`, timestamp de réponse, `snapshot`) et le Pi valide âge/santé avant normalisation.

---

## 4. Raspberry Pi

Le Pi devient le backend global du nouveau système.

Plateforme de référence observée au lancement :
- Raspberry Pi 3 Model B Plus Rev 1.3 ;
- Arch Linux ARM rolling ;
- architecture `armv7l` ;
- kernel observé `6.18.33-4-rpi` ;
- Python observé `3.14.5` ;
- environ 1 Gio de RAM ;
- stockage principal sur microSD ;
- IPv6 désactivé sur `bluebox`.

Socle retenu pour la V1 :

```text
Mosquitto natif
+
un seul service applicatif Python "pulsedeck-hub"
+
systemd / journald
```

L'interface d'administration du hub est implémentée dans le même service applicatif avec FastAPI/Uvicorn et une interface HTML légère. La configuration applicative est en TOML. Les secrets des services distants restent séparés de la configuration versionnée. La configuration fonctionnelle normale des collectors se fait depuis PulseDeck Admin.

Runtime hub retenu à partir de `patch_0003` :
- utilisateur système `pulsedeck` ;
- application sous `/opt/pulsedeck` ;
- configuration sous `/etc/pulsedeck/pulsedeck.toml` ;
- état runtime sous `/var/lib/pulsedeck` ;
- environnement Python dédié sous `/opt/pulsedeck/venv` ;
- déploiement possible par un script autonome sans clone du dépôt.

Le premier service actif du hub maintient `pulsedeck/v1/system/availability`, avec retained QoS 1, Last Will et reconnexion automatique MQTT. Ce runtime a été déployé et validé sur `bluebox` le 27 septembre 2026 : service systemd actif et payload retained `schema=1/state=online` observé.

Le déploiement Raspberry Pi utilise un bootstrap unique `scripts/install.sh`, un lanceur maître persistant et trois scripts de travail. Sur une cible neuve, `install.sh` télécharge et valide la syntaxe de `pulsedeck.sh`, l’installe sous `/usr/local/sbin/pulsedeck`, initialise le cache de l’installateur puis lui délègue l’installation complète. Ensuite, `/usr/local/sbin/pulsedeck` devient l’unique point d’entrée opérationnel normal. Il rafraîchit `pulsedeck.sh`, `setup_pi.sh`, `bootstrap_pi.sh` et `deploy_hub.sh` depuis la référence Git sélectionnée, valide leur syntaxe shell, ne remplace que les copies de cache modifiées sous `/var/lib/pulsedeck/installer/scripts/`, puis exécute le `setup_pi.sh` rafraîchi. `bootstrap_pi.sh` gère le socle système/Mosquitto et `deploy_hub.sh` le service applicatif. Les étapes déterministes sont automatiques. Les scripts installent et réparent le socle technique ; les clés, filtres et réglages métier des collectors sont configurés dans PulseDeck Admin.

À partir de `patch_0007`, le premier collector actif est Weather avec OpenWeather One Call API 4.0. Le hub utilise les endpoints `current`, `timeline/1h` et `timeline/1day`, en unités métriques et en français. Les cadences V1 sont 10 minutes pour `current`, 30 minutes pour les prévisions horaires et 3 heures pour les prévisions quotidiennes. La clé OpenWeather est stockée séparément dans `/etc/pulsedeck/secrets/openweather_api_key` et n'est jamais placée dans la configuration versionnée. Depuis `patch_0008`, Weather est configuré et testé depuis PulseDeck Admin, qui recharge le collector sans redémarrage manuel du service.

À partir de `patch_0010-1`, News utilise NewsAPI v2. Les appels fournisseur sont exclusivement en HTTPS et la clé est envoyée uniquement dans le header `X-Api-Key`, jamais dans la query string. À partir de `patch_0012`, le contrat Admin/fournisseur suit les paramètres propres à chaque endpoint NewsAPI : `top-headlines` supporte `q`, `sources`, `country` et `category` avec la règle d’exclusion documentée pour `sources`, tandis que `everything` supporte `q`, `searchIn`, `sources`, `domains`, `excludeDomains`, `from`, `to`, `language` et `sortBy`. PulseDeck fixe `page=1` pour le snapshot courant et mappe `max_articles` sur `pageSize`. Le hub publie `news/availability` et `news/latest` en retained QoS 1 et conserve le dernier snapshot valide lors d'un échec fournisseur. La clé NewsAPI est stockée dans `/etc/pulsedeck/secrets/newsapi_api_key`. À partir de `patch_0013`, News prend aussi en charge GNews v4 comme fournisseur sélectionnable. GNews utilise `top-headlines` ou `search`, HTTPS et `X-Api-Key` ; `search` impose `q` (200 caractères maximum) et Admin expose les champs GNews de langue/pays/catégorie/champs de recherche/nullable/dates/tri. Les clés NewsAPI et GNews restent séparées dans `/etc/pulsedeck/secrets/newsapi_api_key` et `/etc/pulsedeck/secrets/gnews_api_key`. Les deux fournisseurs sont normalisés vers le même schéma MQTT News.

Éviter les microservices, conteneurs et dépendances d'infrastructure non nécessaires au départ.

Structure initiale :

```text
hub/
├── pyproject.toml
└── src/pulsedeck_hub/
    ├── collectors/
    ├── mqtt/
    ├── health/
    ├── admin/
    ├── config.py
    ├── logging_setup.py
    └── main.py

config/
docs/pi/
scripts/
systemd/
```

Responsabilités :
- appels aux API Internet ;
- HTTPS/TLS vers les services distants ;
- gestion des clés API ;
- connexions persistantes ;
- protocoles propriétaires ;
- collecte Weather, News, Printer et machines supervisées configurables ;
- normalisation des données ;
- cache ;
- publication MQTT ;
- disponibilité des sources ;
- API et interface Web d'administration légère.

---

## 5. ESP32-4848S040C_I

Le firmware ESP32 est centré sur l'interface et non sur la collecte Internet.

Responsabilités :

```text
Wi-Fi
MQTT
NTP
cache local
état des données
navigation
LVGL 9
widgets
graphes
animations
interaction tactile
```

L'ESP32 doit rester autonome pour :
- l'heure ;
- l'interface ;
- la navigation ;
- le rendu ;
- l'affichage des dernières données valides.

Une perte du Pi ou de MQTT ne doit pas rendre l'interface inutilisable.

---

## 6. Contrat MQTT

Le broker V1 est Mosquitto, accessible uniquement sur le LAN IPv4, port TCP `1883`. Il n'est pas exposé à Internet. Pour ce périmètre domestique, la V1 n'active ni authentification MQTT, ni ACL, ni TLS. Ces choix devront être réévalués si le périmètre réseau change ou si MQTT porte ultérieurement des commandes sensibles.

Le namespace versionné retenu est `pulsedeck/v1/...`.

Topics initiaux :

```text
pulsedeck/v1/system/availability

pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily

pulsedeck/v1/news/availability
pulsedeck/v1/news/latest

pulsedeck/v1/printer/<id>/availability
pulsedeck/v1/printer/<id>/status
pulsedeck/v1/printer/<id>/job
pulsedeck/v1/printer/<id>/thumbnail

pulsedeck/v1/machine/<id>/availability
pulsedeck/v1/machine/<id>/dashboard
```

À partir de `patch_0022`, les PC et serveurs supervisés forment une flotte configurable sous `[collectors.machines]` et des tables répétées `[[collectors.machines.devices]]`. À partir de `patch_0023`, le parcours Admin normal commence uniquement par le host/IP de l’Agent (et éventuellement un port non standard) : le Pi lit `/v1/snapshot`, préremplit `id`/`name` depuis l’Agent, propose un `type` modifiable (`server`, `pc`, `laptop`, `other`) à partir des capacités, et conserve host/port modifiables. Chaque entrée enregistrée possède un `id` logique stable, un `name` affiché, un `type`, un `host`, un `port` et un état activé configurés par l’utilisateur. `192.168.0.1` reste uniquement un exemple de saisie ; aucune adresse de machine supervisée n’est compilée dans le hub. Le Pi interroge chaque PulseDeck Agent activé via HTTP en lecture seule (`GET /v1/snapshot`, port TCP `8765` par défaut), valide fraîcheur/santé, normalise le payload réseau Agent et publie en retained QoS 1 schéma 1 sous `machine/<id>/availability` et `machine/<id>/dashboard`. CPU, mémoire et réseau sont les capacités Agent obligatoires ; les données GPU sont normalisées lorsque l’Agent les annonce.

Politique QoS V1 :
- QoS 1 pour les états, disponibilités et snapshots applicatifs ;
- QoS 0 pour d'éventuels flux rapides et éphémères ;
- QoS 2 non utilisé.

Les payloads doivent être :
- stables ;
- versionnés ;
- simples à parser ;
- déjà normalisés ;
- adaptés à l'affichage ;
- accompagnés d'un timestamp.

Le schéma JSON exact reste défini application par application avant implémentation. Weather (`patch_0007`), News (`patch_0010-1`) et Machines (`patch_0022`) disposent de contrats schéma 1 fixés côté hub.

Exemple :

```json
{
  "ts": 1790335000,
  "online": true,
  "data": {
    "temp": 18.6,
    "humidity": 72,
    "pressure": 1017
  }
}
```

---

## 7. Retained messages et disponibilité

Utiliser les fonctions MQTT pour accélérer les reprises :
- retained messages pour les derniers états ;
- Last Will pour les disponibilités ;
- reconnexion automatique ;
- resynchronisation immédiate après reboot.

Topics de disponibilité retained :

```text
pulsedeck/v1/system/availability
pulsedeck/v1/weather/availability
pulsedeck/v1/news/availability
pulsedeck/v1/machine/<id>/availability
pulsedeck/v1/printer/availability
```

L'ESP32 conserve en plus une logique locale basée sur l'âge des données :

```text
fresh
stale
offline
```

---

## 8. Architecture firmware ESP32

Organisation envisagée :

```text
src/
├── apps/
│   ├── home/
│   ├── weather/
│   ├── printer/
│   ├── pc/
│   └── network/
│
├── services/
│   ├── mqtt/
│   ├── time/
│   ├── settings/
│   └── storage/
│
├── models/
│
├── ui/
│   ├── navigation/
│   ├── widgets/
│   ├── graphs/
│   └── theme/
│
└── main/
```

Chaque application doit surtout contenir :
- son modèle de données ;
- ses abonnements MQTT ;
- sa logique d'affichage ;
- ses widgets LVGL.

Elle ne doit pas réimplémenter HTTP, TLS, authentification distante ou protocoles propriétaires.

---

## 9. UI et animations

Le nouveau projet peut utiliser davantage les ressources du ESP32-S3 pour le rendu.

Objectifs :
- transitions fluides ;
- widgets animés ;
- graphes ;
- jauges ;
- icônes météo animées ;
- progression Printer animée ;
- états online/offline visuels ;
- plusieurs pages par application.

Règles initiales :
- animations courtes ;
- redessiner uniquement les zones utiles ;
- cible raisonnable de 15 à 30 FPS ;
- mesurer rendu et flush ;
- surveiller PSRAM, heap interne, DMA et stacks.

---

## 10. Applications envisagées

### Home

Vue synthétique :
- heure ;
- météo ;
- PC ;
- Printer ;
- réseau ;
- notifications importantes.

### Weather

Fournisseur V1 : OpenWeather One Call API 4.0. Le Raspberry Pi publie des snapshots normalisés sur `weather/current`, `weather/hourly` et `weather/daily` ainsi qu'un état séparé sur `weather/availability`. Les erreurs fournisseur ne suppriment pas les derniers retained valides.

Plusieurs pages possibles :
- météo actuelle ;
- prévisions horaires ;
- prévisions quotidiennes ;
- pluie ;
- vent ;
- humidité ;
- pression ;
- lever/coucher du soleil ;
- graphes.

### News

Fournisseurs News V1 : NewsAPI v2 et GNews v4. Le fournisseur actif se choisit dans PulseDeck Admin. NewsAPI utilise `top-headlines` / `everything` ; GNews utilise `top-headlines` / `search`. Les deux utilisent HTTPS avec `X-Api-Key`, les champs propres au fournisseur sont affichés dynamiquement, la pagination reste fixée à la page 1 et les réponses sont normalisées vers `news/latest` / `news/availability`. Le contenu long fournisseur n'est pas republié afin de garder le payload compact pour l'ESP32.

### Printer

Le Pi maintient les informations à jour pendant une impression :
- état ;
- progression ;
- couche ;
- durée écoulée ;
- durée restante ;
- heure estimée de fin ;
- miniature ;
- températures si disponibles ;
- historique court du job.

Quand l'utilisateur revient sur l'écran Printer, l'ESP32 dispose déjà de données récentes.

### Machines supervisées

Les métriques machines sont fournies au Pi par des instances PulseDeck Agent. Le même code Agent sert tous les PC/serveurs supervisés. Les profils de déploiement initiaux restent des exemples utiles plutôt que des slots applicatifs fixes :
- mini-serveur : CPU + MEMORY + NETWORK ;
- PC gamer : CPU + MEMORY + NETWORK + GPU.

À partir de `patch_0023`, PulseDeck Admin simplifie l’ajout d’une machine : saisir l’IP/hostname de l’Agent, le détecter, puis relire/modifier l’ID, le nom affiché, le type, le host et le port préremplis avant enregistrement. Les cartes existantes restent entièrement modifiables et testables. La flotte conserve le même modèle de liste d’équipements que Printer : activer/désactiver ou retirer une machine sans modifier le code du hub. Le Pi porte l’état applicatif normalisé et la publication MQTT, interroge chaque Agent configuré indépendamment, conserve les télémétries optionnelles indisponibles à `null`, puis publie en retained QoS 1 sous `machine/<id>/availability` et `machine/<id>/dashboard`. Cadence de polling, timeout, seuil d’échecs consécutifs et âge maximal du snapshot sont des réglages de flotte. Retirer une machine efface ses topics retained machine.

Les données de dashboard peuvent inclure :
- CPU ;
- RAM ;
- réseau ;
- GPU lorsqu’il est activé ;
- températures ;
- fréquences lorsqu’elles s’appliquent ;
- puissance lorsqu’elle est disponible ;
- historique court.

### Network

Possibilités :
- Internet ;
- Raspberry Pi ;
- broker MQTT ;
- latence ;
- Wi-Fi/RSSI ;
- IP/gateway ;
- services LAN ;
- NAS ;
- Home Assistant ;
- autres équipements.

---

## 11. Principes à conserver

1. L'ESP32 est un terminal graphique intelligent, pas un agrégateur d'API Internet.
2. Le Pi centralise protocoles, secrets et collectors.
3. MQTT est le bus de données principal.
4. Les données sont normalisées avant publication.
5. Les contrats sont versionnés.
6. L'ESP32 garde son NTP autonome.
7. Les dernières données restent visibles en cas de perte du Pi.
8. Les données anciennes sont explicitement `stale`.
9. Une application ne recrée pas sa propre pile réseau.
10. Les gros traitements restent côté Pi lorsqu'ils y sont plus adaptés.
11. L'UI est indépendante de la fréquence réelle de collecte.
12. Une nouvelle app doit pouvoir être ajoutée sans modifier les autres.
13. La documentation du projet, utilisateur et opérationnelle est maintenue en anglais et en français ; l'anglais fait référence.

---

## 12. Plan de développement

### Phase 0 — Bring-up matériel

Valider :
- ESP32-4848S040C_I ;
- écran ST7701 ;
- tactile ;
- PSRAM ;
- Wi-Fi ;
- LVGL 9 ;
- timings RGB ;
- rendu 480 × 480 ;
- stabilité framebuffer.

### Phase 1 — Infrastructure Pi

Installer :
- Mosquitto ;
- service hub minimal ;
- configuration ;
- logs ;
- publication d'un topic de test.

### Phase 2 — Firmware MQTT minimal

ESP32 :
- Wi-Fi ;
- NTP ;
- MQTT ;
- reconnexion ;
- retained messages ;
- écran de diagnostic MQTT.

### Phase 3 — Première application

Weather sert d'application de référence. `patch_0007` implémente le collector Pi et le contrat MQTT Weather V1 avec OpenWeather One Call 4.0. Restent à réaliser côté ESP32 :
- cache ESP ;
- premier écran LVGL 9 ;
- première animation ;
- validation du modèle d'application de bout en bout.

### Phase 4 — News

Intégrer le flux News de référence :
- fournisseur NewsAPI v2 / GNews v4 sélectionnable ;
- HTTPS ;
- authentification `X-Api-Key` ;
- endpoints et filtres propres au fournisseur ;
- snapshot MQTT normalisé retained ;
- configuration via PulseDeck Admin.

### Phase 5 — Printer

Déplacer progressivement vers le Pi :
- connexion persistante ;
- suivi de job ;
- thumbnail ;
- statut MQTT normalisé.

### Phase 6 — Agents machines

Déployer et valider PulseDeck Agent, puis intégrer les métriques machines via le Raspberry Pi :
- valider la collecte locale `agent-002`, la configuration YAML, le service systemd et les chemins d’installation/mise à jour sur le mini-serveur ;
- second déploiement sur le PC gamer avec CPU + MEMORY + NETWORK + GPU ;
- valider de bout en bout le transport HTTP Agent sur plusieurs machines configurées ;
- valider le schéma MQTT 1 dynamique `machine/<id>/...`, y compris la télémétrie GPU optionnelle ;
- valider la découverte par IP/hostname, le préremplissage depuis l’Agent, le type machine modifiable et les opérations ajout/modification/test/activation-désactivation/suppression depuis PulseDeck Admin ;
- normaliser l’état machine sur le Pi avant publication MQTT et exposer disponibilité online/offline plus dashboard par machine.

### Phase 7 — UI avancée

Ajouter :
- animations ;
- widgets partagés ;
- graphes ;
- thèmes ;
- transitions ;
- écran Home.

### Phase 8 — Applications supplémentaires

Ajouter de nouvelles apps seulement après stabilisation du socle MQTT/UI.

---

## 13. Décisions à prendre au lancement

À définir avant le développement complet :
- schéma exact des payloads applicatifs hors Weather, News et Machines ;
- politique de cache ;
- cadence des collectors futurs/non implémentés qui ne disposent pas encore de leur propre contrat ;
- version ESP-IDF ;
- version LVGL 9 ;
- driver ST7701 ;
- driver tactile ;
- utilisation ou non de EEZ Studio ;
- OTA ;
- gestion des assets/images.

---

## 14. Hors périmètre V1

Ne pas complexifier la V1 avec :
- cluster MQTT ;
- Kubernetes ;
- base de données lourde ;
- nombreux microservices ;
- cloud obligatoire ;
- historique long terme ;
- système de plugins dynamique sur ESP32.

Ces éléments seront ajoutés uniquement si un besoin concret apparaît.

---

## 15. Objectif de la V1

Prouver la chaîne complète :

```text
source de données
        ↓
collector Raspberry Pi
        ↓
MQTT
        ↓
ESP32
        ↓
cache local
        ↓
LVGL 9
        ↓
écran 480 × 480
```

Une V1 réussie doit démontrer :
- liaison Pi ↔ ESP32 stable ;
- reprise après coupure MQTT ;
- retained messages ;
- cache local ;
- états `fresh/stale/offline` ;
- une application complète ;
- navigation fluide ;
- une première animation ;
- stabilité mémoire sur plusieurs heures.

---

## 16. Positionnement final

PulseMon reste le projet existant, stable et fonctionnel.

Le nouveau projet est une plateforme distincte construite autour de :

```text
Raspberry Pi = données
MQTT         = bus
ESP32-S3     = interface
LVGL 9       = rendu
480 × 480    = nouvelle UX
```

Cette séparation permet de conserver PulseMon sans régression tout en ouvrant un projet beaucoup plus extensible pour les futures applications.
