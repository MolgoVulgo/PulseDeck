# PROJECT_SCHEMA.fr.md — PulseDeck

**La version anglaise fait référence.** Version anglaise : [`PROJECT_SCHEMA.md`](PROJECT_SCHEMA.md).

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
    - "scripts/install.sh"
    - "scripts/pulsedeck.sh"
    - "scripts/setup_pi.sh"
    - "scripts/deploy_hub.sh"
    - "agent/src/pulsedeck_agent/__main__.py"
    - "agent/scripts/install.sh"
  modules:
    - "Raspberry Pi : orchestration centrale de la collecte, normalisation, agrégation, cache et publication des données"
    - "PulseDeck Agent : collecte locale CPU, mémoire et réseau avec GPU optionnel ; transmet les métriques machine au Raspberry Pi"
    - "MQTT : bus principal entre le backend et l'ESP32"
    - "ESP32-S3 : Wi-Fi, MQTT, NTP local, cache local, état des données et interface LVGL"
  documentation_dirs:
    - "docs/pi"
    - "docs/pi/fr"
    - "agent/docs"
    - "agent/docs/fr"

zones:
  source:
    - "README.md"
    - "README.fr.md"
    - "PROJECT_DESCRIPTION.md"
    - "PROJECT_DESCRIPTION.fr.md"
    - "PROJECT_SCHEMA.md"
    - "PROJECT_SCHEMA.fr.md"
    - "AGENTS.md"
    - "codex-patch-mode.md"
    - "sync-drive.sh"
    - "sync-drive.conf"
    - "sync-drive.filter"
    - "hub/"
    - "agent/"
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
    - "Lors du déploiement complet ultérieur du 2026-09-27, le bootstrap a de nouveau observé une IPv6 globale sur bluebox ; le listener Mosquitto est resté limité à 192.168.0.250:1883 en IPv4."
    - "Bootstrap MQTT exécuté sur bluebox le 2026-09-27 : Mosquitto 2.1.2-2 installé, listener unique 192.168.0.250:1883, QoS 1 retained et restauration après redémarrage validés, zéro échec ; absence de swap conservée comme warning accepté."
    - "Hub applicatif déployé sur bluebox le 2026-09-27 : venv créé, paho-mqtt 2.1.0 et pulsedeck-hub 0.1.0 installés, service systemd actif/activé, pulsedeck/v1/system/availability retained observé avec schema=1 et state=online."
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
    - "Interface d'administration implémentée dans le service hub avec FastAPI et une interface HTML légère, exposée sur l'IPv4 LAN du Pi port 8080."
    - "Runtime hub V1 : /opt/pulsedeck pour application/venv, /etc/pulsedeck/pulsedeck.toml pour configuration, /var/lib/pulsedeck pour état."
    - "Utilisateur systemd du hub : pulsedeck."
    - "Dépendance MQTT Python du hub : paho-mqtt >=2.1,<3, MQTT 3.1.1."
    - "Déploiement hub supporté par scripts/deploy_hub.sh autonome, sans clone du dépôt sur le Pi."
    - "Payload pulsedeck/v1/system/availability schema 1 défini et implémenté dans patch_0003."
    - "Socle MQTT live validé sur bluebox le 2026-09-27 : service Mosquitto actif/activé au boot, listener LAN IPv4 unique, persistence retained opérationnelle."
    - "scripts/setup_pi.sh est l'orchestrateur d'installation complet : bootstrap MQTT puis déploiement du hub."
    - "setup_pi.sh peut fonctionner sans clone du dépôt : il récupère les scripts spécialisés depuis GitHub lorsqu'ils ne sont pas disponibles localement."
    - "À partir de patch_0010-1, /usr/local/sbin/pulsedeck est le lanceur maître persistant : il rafraîchit pulsedeck.sh, setup_pi.sh, bootstrap_pi.sh et deploy_hub.sh depuis la référence Git sélectionnée, valide leur syntaxe shell, ne remplace que les copies de cache modifiées sous /var/lib/pulsedeck/installer/scripts, puis exécute le worker setup rafraîchi."
    - "À partir de patch_0011, scripts/install.sh est l’unique bootstrap de première installation : il télécharge et valide la syntaxe de pulsedeck.sh, installe /usr/local/sbin/pulsedeck, initialise le cache de l’installateur puis délègue l’installation complète au lanceur maître persistant."
    - "Les scripts de déploiement automatisent les opérations déterministes et ne demandent une saisie que lorsqu'une information ne peut pas être déduite ou qu'un choix manuel est nécessaire."
    - "Le mode --non-interactive interdit toute question et transforme une décision manuelle indispensable en échec explicite."
    - "PulseDeck Admin V1 utilise une authentification locale par mot de passe, une session signée, des cookies HttpOnly/SameSite=Strict et reste limité au LAN ; HTTP V1 ne doit pas être exposé à Internet."
    - "Les changements Weather effectués dans l’UI sont testés avant sauvegarde et le collector est rechargé dans le processus hub sans redémarrage manuel."
    - "Weather V1 utilise OpenWeather One Call API 4.0 avec les endpoints current, timeline/1h et timeline/1day."
    - "Weather V1 publie retained/QoS 1 sur weather/availability, weather/current, weather/hourly et weather/daily avec schema 1."
    - "Cadences Weather V1 : current 600 s, hourly 1800 s, daily 10800 s ; horizon hourly 48 h et daily 10 jours."
    - "La clé OpenWeather runtime est séparée du TOML et stockée par défaut dans /etc/pulsedeck/secrets/openweather_api_key ; root et le service pulsedeck peuvent la mettre à jour pour permettre la configuration Web."
    - "À partir de patch_0008, les scripts installent le socle sans questions métier ; Weather est configuré via PulseDeck Admin, qui gère clé, géocodage, test fournisseur, activation et cadences."
    - "À partir de patch_0009, PulseDeck Admin utilise une navigation Vue d’ensemble / Weather / Services / Sécurité, des notifications homogènes et un catalogue commun destiné aux collectors présents et futurs."
    - "Le framework Admin comprend maintenant News, la supervision Agent multi-machines et la configuration multi-imprimantes ; les machines supervisées ne sont plus limitées à un slot PC gamer fixe."
    - "News V1 prend en charge NewsAPI v2 et GNews v4 sélectionnables, exclusivement en HTTPS, avec authentification envoyée uniquement dans le header X-Api-Key."
    - "NewsAPI prend en charge top-headlines/everything ; GNews prend en charge top-headlines/search. Admin affiche dynamiquement les champs propres au fournisseur et les deux réponses sont normalisées vers le même schéma MQTT News."
    - "News V1 utilise par défaut top-headlines, country=fr, aucune restriction de catégorie, max_articles/pageSize=10 et une cadence de 1800 s ; ces valeurs sont configurables dans PulseDeck Admin."
    - "News V1 publie retained/QoS 1 sur news/availability et news/latest avec schema 1 ; le champ fournisseur content n’est pas republié."
    - "Les secrets News sont séparés : /etc/pulsedeck/secrets/newsapi_api_key et /etc/pulsedeck/secrets/gnews_api_key ; PulseDeck Admin ne renvoie aucune clé en clair."
    - "À partir de patch_0010-1, la documentation du projet et opérationnelle est bilingue : anglais prioritaire dans README.md, PROJECT_DESCRIPTION.md, PROJECT_SCHEMA.md et docs/pi/*.md ; miroirs français dans README.fr.md, PROJECT_DESCRIPTION.fr.md, PROJECT_SCHEMA.fr.md et docs/pi/fr/*.md."
    - "PulseDeck Agent V1 utilise un même code pour tous les PC/serveurs supervisés ; mini-serveur et PC gamer sont des profils de déploiement initiaux, pas des slots fixes du hub."
    - "Modules obligatoires PulseDeck Agent V1 : CPU, MEMORY et NETWORK ; GPU est optionnel et activé par configuration."
    - "Profils Agent initiaux : mini-serveur = CPU + MEMORY + NETWORK ; PC gamer = CPU + MEMORY + NETWORK + GPU."
    - "Métriques CPU Agent V1 : utilisation, température et puissance si disponible."
    - "Métriques MEMORY Agent V1 : octets utilisés, octets totaux et pourcentage d’utilisation."
    - "Métriques NETWORK Agent V1 : interface configurée, débits RX/TX et compteurs d’octets RX/TX."
    - "Métriques GPU Agent V1 lorsqu’il est activé : utilisation, température, puissance, fréquences core/mémoire, VRAM utilisée/totale et ventilation si disponible."
    - "À partir de agent-002, la configuration runtime Agent est en YAML sous /etc/pulsedeck-agent/agent.yml."
    - "À partir de agent-002, systemd supervise pulsedeck-agent.service ; l’état diagnostique local est écrit sous /var/lib/pulsedeck-agent/."
    - "À partir de agent-002-1, les méthodes d’installation sont mutuellement exclusives : les systèmes Arch/pacman utilisent uniquement makepkg ; l’installateur standalone est réservé aux systèmes Linux non-Arch et refuse les hôtes Arch/pacman ; les deux utilisent les mêmes sources agent/."
    - "À partir de agent-004, l’installateur Arch construit depuis un checkout temporaire propre du canal distant sélectionné, épingle le build sur le commit Git résolu et ne doit pas dépendre du contenu du working tree local."
    - "À partir de agent-004-1, l’installateur Arch authentifie sudo une seule fois, construit le paquet sans installation pilotée par makepkg, puis l’installe explicitement avec pacman non interactif ; les étapes privilégiées suivantes réutilisent la même autorisation sudo sans demande supplémentaire."
    - "À partir de agent-002, la commande normale de mise à jour est pulsedeck-agent update."
    - "À partir de patch_0021, le transport Agent → Pi V1 est HTTP en lecture seule sur le LAN de confiance : GET /v1/snapshot, port TCP 8765 par défaut, adresse/port d’écoute Agent configurables et cible host/port configurable côté Pi."
    - "patch_0021 définit le schéma réseau Agent 1 comme une enveloppe explicite avec schema=1, protocol=pulsedeck-agent-http, timestamp de réponse et objet snapshot ; le Pi valide âge et santé avant normalisation."
    - "patch_0021 a défini le premier chemin HTTP Agent → Pi ; patch_0022 le généralise en flotte configurable sous [collectors.machines] et des entrées répétées [[collectors.machines.devices]]."
    - "patch_0022 définit le schéma machine 1 dynamique retained QoS 1 sur pulsedeck/v1/machine/<id>/availability et pulsedeck/v1/machine/<id>/dashboard."
    - "Chaque machine possède un id logique stable ainsi qu’un name, host/IP, port et état activé configurés par l’utilisateur ; aucune IP de machine supervisée n’est codée en dur dans le hub. 192.168.0.1 reste uniquement un exemple de documentation/saisie."
    - "PulseDeck Admin permet d’ajouter, modifier, tester, activer/désactiver et retirer des machines supervisées ; retirer une machine efface ses topics retained machine."
  unresolved:
    - "Schémas exacts des payloads applicatifs hors Weather, News et Machines."
    - "Politique exacte de cache."
    - "Cadences des collectors futurs/non implémentés qui ne disposent pas encore d’un contrat propre."
    - "Version ESP-IDF."
    - "Version exacte de LVGL 9."
    - "Driver ST7701."
    - "Driver tactile."
    - "Utilisation ou non de EEZ Studio."
    - "OTA."
    - "Gestion des assets/images."

contracts:
  architecture:
    - "Le Pi reste l’orchestrateur central de collecte, le normaliseur et le producteur MQTT destiné à l’affichage ; les instances Agent locales ne remplacent pas le hub Pi."
    - "PulseDeck Agent collecte uniquement les métriques locales de sa machine ; le Pi interroge l’Agent via le transport HTTP V1 en lecture seule et reste responsable de la normalisation et de la publication MQTT orientée affichage."
    - "Le Pi centralise la collecte, les protocoles distants et la normalisation ; l'ESP32 est centré sur l'interface."
    - "MQTT est le bus principal entre le Pi et l'ESP32."
    - "Une nouvelle application ne recrée pas sa propre pile réseau distante et doit pouvoir être ajoutée sans modifier les autres applications."
    - "Les gros traitements restent côté Pi lorsqu'ils y sont plus adaptés."
  agent:
    - "Un même code PulseDeck Agent sert toutes les machines supervisées en V1."
    - "Modules V1 obligatoires : CPU, MEMORY, NETWORK."
    - "Module V1 optionnel : GPU, activé par configuration."
    - "Profil mini-serveur : CPU + MEMORY + NETWORK."
    - "Profil PC gamer : CPU + MEMORY + NETWORK + GPU."
    - "NETWORK suit l’interface sélectionnée dans le YAML ; interface=auto résout si possible l’interface portant la route par défaut et le collector publie débits RX/TX et compteurs d’octets RX/TX."
    - "Les télémétries optionnelles indisponibles, comme la puissance CPU/GPU ou la ventilation GPU, restent indisponibles et ne sont pas synthétisées à zéro."
    - "La configuration runtime Agent est en YAML sous /etc/pulsedeck-agent/agent.yml ; CPU, MEMORY et NETWORK sont obligatoires et seul GPU possède un switch enabled."
    - "La supervision du service Agent utilise systemd via pulsedeck-agent.service."
    - "L’installation Arch/pacman utilise agent/packaging/arch/install.sh comme entrée utilisateur et agent/packaging/arch/PKGBUILD avec makepkg ; makepkg s’exécute avec un utilisateur normal, la source de build provient d’un checkout distant propre, le commit source exact est épinglé avant packaging et l’installation du paquet est effectuée explicitement via pacman non interactif après une seule authentification sudo."
    - "agent/scripts/install.sh est l’installateur standalone réservé aux systèmes Linux non-Arch et doit refuser les hôtes Arch/pacman avant toute modification système."
    - "L’installation standard utilise agent/scripts/install.sh et un runtime isolé sous /opt/pulsedeck-agent."
    - "Les deux méthodes exposent la commande commune pulsedeck-agent et les mises à jour normales utilisent pulsedeck-agent update."
    - "Le snapshot.json local de agent-002 est un état interne/diagnostique et ne définit pas le payload réseau Agent → Pi."
    - "Le transport HTTP Agent est désactivé sauf activation dans /etc/pulsedeck-agent/agent.yml ; adresse d’écoute et port sont configurables, avec port 8765 par défaut et endpoint snapshot fixe /v1/snapshot."
    - "L’endpoint HTTP Agent V1 est en lecture seule et sans authentification uniquement dans le périmètre LAN de confiance actuel ; il ne doit pas être exposé directement à Internet."
  machines:
    - "La configuration Hub utilise [collectors.machines] et des entrées répétées [[collectors.machines.devices]] avec id stable, nom affiché, host/IP, port et état activé."
    - "Le collector Machines du Pi accepte une ou plusieurs machines configurables, interroge chaque Agent activé indépendamment, rejette les snapshots trop anciens ou non sains et utilise les réglages poll_interval/request_timeout/offline_after_failures/max_snapshot_age."
    - "Le schéma MQTT machine 1 utilise retained QoS 1 sur machine/<id>/availability et machine/<id>/dashboard, où <id> est l’identifiant logique configuré."
    - "Le schéma 1 machine/<id>/dashboard contient schema, ts, source, machine{id,name,host}, agent{id,name}, capabilities et data. data contient toujours cpu{usage_pct,temperature_c,power_w}, memory{used_b,total_b,usage_pct} et network{interface,rx_bps,tx_bps,rx_bytes,tx_bytes} ; gpu{usage_pct,temperature_c,power_w,core_clock_mhz,memory_clock_mhz,vram_used_b,vram_total_b,fan_rpm,fan_pct} est inclus lorsque l’Agent l’annonce/le fournit."
    - "Les télémétries optionnelles indisponibles restent null ; elles ne sont jamais synthétisées à zéro."
    - "machine/<id>/availability utilise le schéma source availability 1 avec source=pulsedeck-agent, state online/offline, ts et last_success/reason optionnels."
    - "Les dashboards machine portent l’identité logique configurée et l’identité/capacités annoncées par l’Agent ; l’id logique n’a pas à être identique à l’id Agent."
    - "PulseDeck Admin prend en charge ajout/modification/test/activation-désactivation/retrait et recharge la flotte à chaud sans redémarrer le hub."
    - "L’ancien [collectors.mini_server] de patch_0021 reste accepté pour migration en mémoire ; le premier enregistrement Machines dans Admin persiste le format multi-équipements canonique et supprime la section legacy."
  weather:
    - "Provider V1 : OpenWeather One Call API 4.0."
    - "Le collector utilise current, timeline/1h et timeline/1day ; les timelines 1min et 15min restent hors patch_0007."
    - "Les snapshots Weather restent retained lors d'une erreur fournisseur ; weather/availability porte l'état de la source."
    - "Les unités MQTT sont normalisées explicitement en Celsius, hPa, pourcentage, m/s et millimètres selon les champs."
  news:
    - "Providers V1 : NewsAPI v2 et GNews v4, sélectionnables depuis Admin."
    - "Transport fournisseur : HTTPS uniquement."
    - "Authentification fournisseur : header X-Api-Key uniquement ; la clé n’est jamais placée dans la query string."
    - "Modes V1 : top-headlines ou everything. top-headlines supporte q/sources/country/category et interdit de combiner sources avec country/category. everything supporte q/searchIn/sources/domains/excludeDomains/from/to/language/sortBy."
    - "Valeurs initiales V1 : country=fr, catégorie sans restriction, lang=fr pour everything, sort_by=publishedAt, max_articles/pageSize=10, interval=1800 s, timeout=15 s ; page reste fixé à 1 pour le snapshot courant."
    - "Payload news/latest schema 1 : feed metadata + tableau articles normalisé ; provider content volontairement exclu ; publishedAt converti en published_ts Unix."
    - "news/availability et news/latest sont retained en QoS 1 ; le dernier snapshot valide reste disponible lors d’un échec fournisseur."
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
    - "La clé OpenWeather n'est jamais versionnée et reste confinée à /etc/pulsedeck ; PulseDeck Admin peut la remplacer mais ne la renvoie jamais en clair via son API."
    - "Les clés NewsAPI/GNews ne sont jamais versionnées ni placées dans les URL fournisseur ; elles restent dans des fichiers séparés sous /etc/pulsedeck/secrets et ne sont jamais renvoyées en clair par PulseDeck Admin."
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
    - "La documentation du projet, utilisateur et opérationnelle est maintenue en anglais et en français ; l’anglais est prioritaire et fait référence en cas de divergence."
    - "README.md, PROJECT_DESCRIPTION.md, PROJECT_SCHEMA.md, agent/README.md, agent/docs/*.md et docs/pi/*.md portent les versions anglaises principales ; README.fr.md, PROJECT_DESCRIPTION.fr.md, PROJECT_SCHEMA.fr.md, agent/README.fr.md, agent/docs/fr/*.md et docs/pi/fr/*.md portent les miroirs français."
  project_specific:
    - "Ne pas complexifier la V1 avec cluster MQTT, Kubernetes, base de données lourde, nombreux microservices, cloud obligatoire, historique long terme ou système de plugins dynamique sur ESP32 sans besoin concret."

validation:
  commands:
    - command: "PYTHONPATH=agent/src python -m unittest discover -s agent/tests -v"
      scope: "tests unitaires PulseDeck Agent sans installation ni transport réseau"
      mode: "targeted"
    - command: "PYTHONPATH=agent/src python -m pulsedeck_agent --config agent/config/pulsedeck-agent.example.yml config validate"
      scope: "validation du YAML exemple PulseDeck Agent"
      mode: "targeted"
    - command: "./scripts/pulsedeck.sh --check"
      scope: "préflight complet Raspberry Pi : socle MQTT puis runtime hub"
      mode: "external_or_live"
    - command: "./scripts/deploy_hub.sh --check"
      scope: "préflight déploiement/runtime du hub PulseDeck"
      mode: "external_or_live"
  forbidden_automatic:
    - "installation ou mise à jour automatique de dépendances hors exécution volontaire des scripts de déploiement PulseDeck"
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
  sensitive_runtime_files:
    - "/etc/pulsedeck/secrets/openweather_api_key"
    - "/etc/pulsedeck/secrets/newsapi_api_key"
    - "/etc/pulsedeck/secrets/gnews_api_key"
```

## Statut

Les contrats applicatifs ci-dessus proviennent uniquement de `PROJECT_DESCRIPTION.md` et des paramètres CREATE explicitement fournis. Les éléments marqués `unresolved` ne sont pas des règles d'implémentation.
