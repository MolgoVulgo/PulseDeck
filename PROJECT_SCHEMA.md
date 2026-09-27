# PROJECT_SCHEMA.md — PulseDeck

```yaml
project:
  name: "PulseDeck"
  slug: "PulseDeck"
  description: "Plateforme d'affichage domestique extensible : Raspberry Pi pour la collecte/normalisation, MQTT comme bus de données, ESP32-S3 comme interface graphique LVGL 9."
  stack:
    - "Raspberry Pi"
    - "MQTT"
    - "ESP32-S3 / ESP32-4848S040C_I"
    - "LVGL 9"
  local_root: "/home/kaj/Projets/PulseDeck/"
  drive_remote: "gdrive"
  drive_path: "PulseDeck"

architecture:
  entrypoints:
    - "hub/src/pulsedeck_hub/main.py"
    - "scripts/setup_pi.sh"
    - "scripts/deploy_hub.sh"
  modules:
    - "Raspberry Pi : collecte, normalisation, agrégation, cache et publication des données"
    - "MQTT : bus principal entre le backend et l'ESP32"
    - "ESP32-S3 : Wi-Fi, MQTT, NTP local, cache local, état des données et interface LVGL"
  documentation_dirs:
    - "docs/pi"

zones:
  source:
    - "PROJECT_DESCRIPTION.md"
    - "PROJECT_SCHEMA.md"
    - "AGENTS.md"
    - "codex-patch-mode.md"
    - "sync-drive.sh"
    - "sync-drive.conf"
    - "sync-drive.filter"
    - "hub/"
    - "config/"
    - "docs/pi/"
    - "scripts/"
    - "systemd/"
  generated:
    - "REPO_INDEX.json"
  runtime: []
  temporary: []
  protected:
    - "web/"
    - "bootstrap/"
    - "patch/"
    - "diagnostics/"
  published_data: []

knowledge:
  observed:
    - "CREATE initialisé à partir de la description canonique fournie par l'utilisateur ; aucun code applicatif local n'avait été inspecté lors de l'initialisation."
    - "Le dossier Drive cible était vide avant la création des zones de transport."
    - "Plateforme Pi observée le 2026-09-27 : Raspberry Pi 3 Model B Plus Rev 1.3, Arch Linux ARM armv7l, kernel 6.18.33-4-rpi, Python 3.14.5, 917 MiB de RAM, environ 18 GiB libres sur la racine."
    - "IPv6 a été désactivé sur bluebox par choix utilisateur."
    - "Bootstrap MQTT exécuté sur bluebox le 2026-09-27 : Mosquitto 2.1.2-2 installé, listener unique 192.168.0.250:1883, QoS 1 retained et restauration après redémarrage validés, zéro échec ; absence de swap conservée comme warning accepté."
  documented:
    - "Le Raspberry Pi collecte, normalise et agrège les données ; l'ESP32 affiche, anime, met en cache et gère l'interaction utilisateur."
    - "MQTT est le bus de données principal."
    - "L'ESP32 cible est l'ESP32-4848S040C_I avec écran 480 x 480 et une UI conçue pour LVGL 9."
    - "L'ESP32 conserve son NTP autonome, son interface, sa navigation, son rendu et les dernières données valides en cas de perte du Pi ou de MQTT."
    - "Les données publiées par MQTT sont prévues stables, versionnées, normalisées, simples à parser, adaptées à l'affichage et accompagnées d'un timestamp."
    - "Le contrat MQTT prévoit retained messages, Last Will, reconnexion automatique et resynchronisation après reboot."
    - "Les états locaux de fraîcheur sont fresh, stale et offline."
    - "Une application ESP32 ne doit pas réimplémenter HTTP, TLS, authentification distante ou protocoles propriétaires."
    - "La V1 vise à démontrer la chaîne source -> collector Raspberry Pi -> MQTT -> ESP32 -> cache local -> LVGL 9 -> écran 480 x 480."
    - "La V1 exclut notamment cluster MQTT, Kubernetes, base de données lourde, nombreux microservices, cloud obligatoire, historique long terme et système de plugins dynamique ESP32."
  confirmed:
    - "Nom du projet : PulseDeck."
    - "Racine locale prévue : /home/kaj/Projets/PulseDeck/."
    - "Destination Drive physique : dossier ID 1EgquPKEO5GjlMZ6ZQccmnFlgqY6THjbr."
    - "Remote rclone : gdrive."
    - "Chemin logique rclone : PulseDeck."
    - "OS Raspberry Pi V1 : Arch Linux ARM rolling sur armv7l."
    - "Langage du hub : Python 3 ; runtime observé Python 3.14.5."
    - "Broker MQTT V1 : Mosquitto natif, TCP 1883, LAN IPv4 uniquement, jamais exposé directement à Internet."
    - "MQTT V1 sans authentification, sans ACL et sans TLS dans le périmètre LAN domestique actuel."
    - "Namespace MQTT V1 : pulsedeck/v1/."
    - "QoS MQTT V1 : QoS 1 pour états/snapshots, QoS 0 pour flux rapides éventuels, QoS 2 non utilisé."
    - "Les topics d'état et de disponibilité V1 sont retained ; les flux rapides éventuels ne le sont pas."
    - "Configuration applicative prévue en TOML ; les secrets éventuels restent séparés des fichiers versionnés."
    - "Supervision : systemd ; logs : journald."
    - "Interface d'administration prévue dans le service hub avec FastAPI et une interface HTML légère."
    - "Runtime hub V1 : /opt/pulsedeck pour application/venv, /etc/pulsedeck/pulsedeck.toml pour configuration, /var/lib/pulsedeck pour état."
    - "Utilisateur systemd du hub : pulsedeck."
    - "Dépendance MQTT Python du hub : paho-mqtt >=2.1,<3, MQTT 3.1.1."
    - "Déploiement hub supporté par scripts/deploy_hub.sh autonome, sans clone du dépôt sur le Pi."
    - "Payload pulsedeck/v1/system/availability schema 1 défini et implémenté dans patch_0003."
    - "Socle MQTT live validé sur bluebox le 2026-09-27 : service Mosquitto actif/activé au boot, listener LAN IPv4 unique, persistence retained opérationnelle."
  unresolved:
    - "Schéma exact des payloads applicatifs."
    - "Politique exacte de cache."
    - "Cadence des collectors."
    - "Version ESP-IDF."
    - "Version exacte de LVGL 9."
    - "Driver ST7701."
    - "Driver tactile."
    - "Utilisation ou non de EEZ Studio."
    - "OTA."
    - "Gestion des assets/images."

contracts:
  architecture:
    - "Le Pi centralise la collecte, les protocoles distants et la normalisation ; l'ESP32 est centré sur l'interface."
    - "MQTT est le bus principal entre le Pi et l'ESP32."
    - "Une nouvelle application ne recrée pas sa propre pile réseau distante et doit pouvoir être ajoutée sans modifier les autres applications."
    - "Les gros traitements restent côté Pi lorsqu'ils y sont plus adaptés."
  persistence:
    - "L'ESP32 conserve localement les dernières données valides afin de rester utilisable lorsque le Pi ou MQTT est indisponible."
    - "La politique détaillée de cache reste unresolved."
  generated_sources:
    - "REPO_INDEX.json est généré par sync-drive.sh à partir du même filtre que la publication et reste hors baseline source."
  runtime:
    - "L'ESP32 garde l'heure, l'interface, la navigation et le rendu utilisables indépendamment de la disponibilité du Pi/MQTT."
    - "Les données anciennes sont explicitement marquées stale ; les états locaux prévus sont fresh/stale/offline."
    - "L'UI est indépendante de la fréquence réelle de collecte."
  security:
    - "Les clés API, HTTPS/TLS vers les services Internet et protocoles propriétaires sont centralisés côté Pi."
    - "Le broker MQTT V1 reste limité au LAN IPv4 et ne doit jamais être exposé directement à Internet."
    - "Dans le périmètre domestique LAN actuel, MQTT V1 fonctionne sans authentification, sans ACL et sans TLS."
    - "Si le périmètre réseau change ou si MQTT porte des commandes sensibles, le modèle de sécurité MQTT doit être réévalué."
  compatibility:
    - "Matériel écran ciblé : ESP32-4848S040C_I, 480 x 480."
    - "LVGL 9 est la cible UI ; sa version exacte reste unresolved."
    - "Le bring-up doit valider écran ST7701, tactile, PSRAM, Wi-Fi, timings RGB, rendu 480 x 480 et stabilité framebuffer."
  validation:
    - "La V1 doit démontrer une liaison Pi <-> ESP32 stable."
    - "La V1 doit démontrer la reprise après coupure MQTT, retained messages, cache local et états fresh/stale/offline."
    - "La V1 doit comporter une application complète, une navigation fluide, une première animation et une stabilité mémoire sur plusieurs heures."
  documentation:
    - "PROJECT_DESCRIPTION.md est la source canonique de description du projet."
  project_specific:
    - "Ne pas complexifier la V1 avec cluster MQTT, Kubernetes, base de données lourde, nombreux microservices, cloud obligatoire, historique long terme ou système de plugins dynamique sur ESP32 sans besoin concret."

validation:
  commands:
    - command: "./scripts/setup_pi.sh --check"
      scope: "préflight Raspberry Pi, réseau et prérequis PulseDeck"
      mode: "external_or_live"
    - command: "./scripts/deploy_hub.sh --check"
      scope: "préflight déploiement/runtime du hub PulseDeck"
      mode: "external_or_live"
  forbidden_automatic:
    - "installation ou mise à jour automatique de dépendances"
    - "synchronisation globale Drive -> dépôt local"
    - "git commit/push/reset/clean/restore/stash sans instruction explicite"
  failure_policy: "stop_and_report"

transport:
  patch_dir: "patch"
  diagnostics_dir: "diagnostics"
  index_file: "REPO_INDEX.json"
  additional_exclusions:
    - "/web/**"
    - "/bootstrap/**"
    - "/patch/**"
    - "/diagnostics/**"
    - "/REPO_INDEX.json"

diagnostics:
  patch_results: true
  runtime_sources: []
  published_sources: []
  required_outputs: []

security:
  secret_patterns: []
  sensitive_runtime_files: []
```

## Statut

Les contrats applicatifs ci-dessus proviennent uniquement de `PROJECT_DESCRIPTION.md` et des paramètres CREATE explicitement fournis. Les éléments marqués `unresolved` ne sont pas des règles d'implémentation.
