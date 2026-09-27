# Nouveau projet — Hub Raspberry Pi + MQTT + ESP32-4848S040C_I

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
                        Raspberry Pi
                ┌──────────────────────────┐
Internet ──────►│ Weather collector        │
                │ News collector           │
PC ────────────►│ PC metrics collector     │
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

Principe fondamental : le Pi collecte et normalise les données ; l'ESP32 affiche, anime, met en cache et gère l'interaction utilisateur.

---

## 4. Raspberry Pi

Le Pi devient le backend global du nouveau système.

Socle initial recommandé :

```text
Mosquitto
+
un seul service applicatif "hub"
```

Éviter les microservices au départ.

Structure possible :

```text
hub/
├── collectors/
│   ├── weather.py
│   ├── news.py
│   ├── printer.py
│   ├── pc.py
│   └── network.py
├── models/
├── mqtt/
├── cache/
├── config/
└── main.py
```

Responsabilités :
- appels aux API Internet ;
- HTTPS/TLS ;
- gestion des clés API ;
- connexions persistantes ;
- protocoles propriétaires ;
- collecte Printer ;
- collecte PC ;
- collecte réseau ;
- normalisation des données ;
- cache ;
- publication MQTT ;
- disponibilité des sources.

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

Prévoir un namespace versionné dès l'origine.

Exemple :

```text
hub/v1/system/availability

hub/v1/weather/current
hub/v1/weather/hourly
hub/v1/weather/daily

hub/v1/news/latest

hub/v1/printer/availability
hub/v1/printer/status
hub/v1/printer/job
hub/v1/printer/thumbnail

hub/v1/pc/main/availability
hub/v1/pc/main/dashboard

hub/v1/network/status
hub/v1/network/services
```

Les payloads doivent être :
- stables ;
- versionnés ;
- simples à parser ;
- déjà normalisés ;
- adaptés à l'affichage ;
- accompagnés d'un timestamp.

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

Topics possibles :

```text
hub/v1/system/availability
hub/v1/pc/main/availability
hub/v1/printer/availability
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

### PC

Dashboard :
- CPU ;
- GPU ;
- RAM ;
- températures ;
- fréquences ;
- puissance ;
- réseau ;
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

Commencer idéalement par Weather :
- collector Pi ;
- contrat MQTT ;
- cache ESP ;
- premier écran LVGL 9 ;
- première animation ;
- validation du modèle d'application.

### Phase 4 — Printer

Déplacer progressivement vers le Pi :
- connexion persistante ;
- suivi de job ;
- thumbnail ;
- statut MQTT normalisé.

### Phase 5 — PC

Intégrer les métriques PC :
- publication MQTT directe ou collecte par le Pi ;
- dashboard ;
- disponibilité online/offline.

### Phase 6 — UI avancée

Ajouter :
- animations ;
- widgets partagés ;
- graphes ;
- thèmes ;
- transitions ;
- écran Home.

### Phase 7 — Applications supplémentaires

Ajouter de nouvelles apps seulement après stabilisation du socle MQTT/UI.

---

## 13. Décisions à prendre au lancement

À définir avant le développement complet :
- nom du nouveau projet ;
- OS Raspberry Pi ;
- langage du hub ;
- authentification MQTT ;
- TLS MQTT ou LAN privé ;
- schéma exact des payloads ;
- QoS ;
- topics retained ;
- politique de cache ;
- cadence des collectors ;
- configuration ;
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
