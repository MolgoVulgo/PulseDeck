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
  entrypoints: []
  modules:
    - "Raspberry Pi : collecte, normalisation, agrégation, cache et publication des données"
    - "MQTT : bus principal entre le backend et l'ESP32"
    - "ESP32-S3 : Wi-Fi, MQTT, NTP local, cache local, état des données et interface LVGL"
  documentation_dirs: []

zones:
  source:
    - "PROJECT_DESCRIPTION.md"
    - "PROJECT_SCHEMA.md"
    - "AGENTS.md"
    - "codex-patch-mode.md"
    - "sync-drive.sh"
    - "sync-drive.conf"
    - "sync-drive.filter"
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
    - "CREATE initialisé à partir de la description canonique fournie par l'utilisateur ; aucun code applicatif local n'a été inspecté."
    - "Le dossier Drive cible était vide avant la création des zones de transport."
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
  unresolved:
    - "OS Raspberry Pi."
    - "Langage du hub."
    - "Authentification MQTT."
    - "TLS MQTT ou LAN privé."
    - "Schéma exact des payloads."
    - "QoS MQTT."
    - "Liste exacte des topics retained."
    - "Politique exacte de cache."
    - "Cadence des collectors."
    - "Format et organisation de la configuration."
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
    - "L'authentification MQTT et le choix TLS MQTT ou LAN privé restent unresolved."
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
  commands: []
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
