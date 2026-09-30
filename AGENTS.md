# AGENTS.md — PulseDeck

> Instructions locales réservées à Codex. Ce document ne constitue pas une instruction pour ChatGPT Web.

## Projet
- Nom : `PulseDeck`
- Description : plateforme d'affichage domestique extensible séparant collecte/normalisation sur Raspberry Pi, transport MQTT et interface graphique sur ESP32-S3.
- Stack : Raspberry Pi + MQTT + ESP32-S3 / ESP32-4848S040C_I + LVGL 9. OS Pi, langage du hub, versions exactes et drivers restent `À DÉFINIR`.

Le dépôt local est la source de vérité locale pour Codex. Drive est publication/transport uniquement.

## Architecture active
Le Raspberry Pi porte l'orchestration centrale de la collecte, les protocoles distants, la normalisation et la publication des données. Les instances PulseDeck Agent collectent uniquement les métriques locales de leurs machines et les transmettent au Pi. MQTT est le bus principal vers l'ESP32, qui porte l'interface, le cache local, les états de fraîcheur, la navigation, le rendu et l'interaction.

Documentation canonique :
- `PROJECT_DESCRIPTION.md` — source canonique détaillée du projet.
- `PROJECT_SCHEMA.md` — contrat descriptif partagé Web/Codex.

Ne pas dupliquer ici les détails déjà maintenus dans une documentation canonique : les référencer.

## Contrats critiques
### Frontières d'architecture
- Le Pi centralise l'orchestration de la collecte, les accès API/HTTPS/TLS distants, les protocoles propriétaires, la normalisation et la publication MQTT destinée à l'affichage.
- PulseDeck Agent collecte uniquement les métriques locales de la machine : CPU, MEMORY et NETWORK obligatoires en V1, GPU optionnel par configuration.
- Profils V1 verrouillés : mini-serveur = CPU + MEMORY + NETWORK ; PC gamer = CPU + MEMORY + NETWORK + GPU.
- Configuration Agent V1 : YAML sous `/etc/pulsedeck-agent/agent.yml`; CPU/MEMORY/NETWORK restent obligatoires, seul GPU est activable/désactivable.
- Service Agent V1 : `pulsedeck-agent.service` sous systemd avec le compte système fixe `pulsedeck-agent` ; état diagnostique local sous `/var/lib/pulsedeck-agent/`, lisible pour `pulsedeck-agent doctor` sans root.
- `pulsedeck-agent doctor` doit vérifier le transport HTTP lorsque `transport.enabled: true` : `/v1/health`, enveloppe `/v1/snapshot`, identité Agent, capacités obligatoires et fraîcheur ; une écoute `0.0.0.0` est testée localement via `127.0.0.1`.
- Installation Agent : méthodes mutuellement exclusives. Sur Arch/pacman, l’entrée utilisateur `agent/packaging/arch/install.sh` doit construire via `makepkg` depuis un checkout distant temporaire propre, épinglé à une révision Git précise, sans dépendre de l’état du checkout local. L’installateur Arch authentifie `sudo` une fois, construit sans `makepkg -i`, installe ensuite le paquet explicitement avec `pacman --noconfirm`, et toutes les opérations privilégiées suivantes doivent rester non interactives ; sur Linux non-Arch, utiliser `agent/scripts/install.sh`, qui doit refuser les hôtes Arch/pacman. Mise à jour normale via `pulsedeck-agent update` sur le même canal.
- Transport Agent -> Pi V1 : HTTP en lecture seule sur le LAN de confiance, `GET /v1/snapshot`, port `8765` par défaut, avec `transport.enabled`, `transport.listen` et `transport.port` dans le YAML Agent ; le schéma réseau 1 utilise `protocol=pulsedeck-agent-http` et le host/port cible reste configuré côté Pi.
- L'ESP32 est centré sur Wi-Fi, MQTT, NTP local, cache local, navigation et UI LVGL.
- Une application ESP32 ne réimplémente pas HTTP, TLS, authentification distante ou protocoles propriétaires.
- Une nouvelle application doit pouvoir être ajoutée sans modifier les autres.
- Les gros traitements restent côté Pi lorsqu'ils y sont plus adaptés.

### Persistance et sources de vérité
- Le dépôt local est la source de vérité locale.
- L'ESP32 conserve les dernières données valides afin que l'interface reste utilisable si le Pi ou MQTT disparaît.
- La politique exacte de cache reste `unresolved` : ne pas l'inventer.

### Générés et données publiées
- `REPO_INDEX.json` est généré par `sync-drive.sh` avec le même filtre que la publication et reste hors baseline source.
- Les payloads MQTT applicatifs doivent rester versionnés, normalisés, adaptés à l'affichage et accompagnés d'un timestamp ; leur schéma exact reste `unresolved`.

### Runtime / compatibilité / sécurité
- Matériel cible : `ESP32-4848S040C_I`, écran 480 × 480.
- LVGL 9 est la cible UI ; version exacte, ESP-IDF et drivers restent `unresolved`.
- L'ESP32 garde un NTP autonome et les états `fresh / stale / offline`.
- Les secrets et clés API destinés aux services distants restent côté Pi.
- Authentification MQTT et TLS MQTT/LAN privé restent `unresolved`.

### Contrats spécifiques au projet
- MQTT est le bus de données principal.
- Utiliser les mécanismes MQTT documentés pour la reprise : retained messages, Last Will, reconnexion automatique et resynchronisation.
- L'UI reste indépendante de la fréquence réelle de collecte.
- Ne pas introduire dans la V1, sans besoin concret confirmé : cluster MQTT, Kubernetes, base de données lourde, nombreux microservices, cloud obligatoire, historique long terme ou plugins dynamiques ESP32.
- Les autres décisions listées `unresolved` dans `PROJECT_SCHEMA.md` et `PROJECT_DESCRIPTION.md` ne doivent pas être transformées en choix implicites.

Seuls les contrats documentés ou explicitement confirmés sont normatifs. Une hypothèse non résolue ne doit pas être transformée en règle.

## Zones du dépôt
Sources :
- fichiers applicatifs réellement créés dans le dépôt ;
- `PROJECT_DESCRIPTION.md`, `PROJECT_SCHEMA.md`, `AGENTS.md`, `codex-patch-mode.md`, `sync-drive.sh`, `sync-drive.conf`, `sync-drive.filter`, `agent/`.

Générés :
- `REPO_INDEX.json` uniquement pour l'index de publication ; hors baseline source.

Runtime / temporaires :
- Hub : conserver les chemins déjà documentés dans `PROJECT_SCHEMA.md`.
- Agent standalone : `/opt/pulsedeck-agent` pour le venv, `/etc/pulsedeck-agent/agent.yml` pour la configuration et `/var/lib/pulsedeck-agent` pour l'état local.
- `bootstrap/`, `patch/` et `diagnostics/` sont des zones de transport hors baseline.

Protégés / publication spéciale :
- `web/` est Web-only et hors baseline locale/index.
- `bootstrap/`, `patch/`, `diagnostics/` et `REPO_INDEX.json` restent hors baseline source.

## Publication et transport
- local -> Drive uniquement ;
- `REPO_INDEX.json` utilise le même filtre que la publication ;
- `patch/` = Web -> Codex, hors baseline ;
- `diagnostics/` = Codex -> Web, hors baseline ;
- jamais de sync globale Drive -> dépôt ;
- récupération d'un patch ciblé uniquement vers un emplacement temporaire.

## Validations
Aucune installation ou mise à jour automatique de dépendances n'est autorisée hors exécution volontaire des installateurs PulseDeck.

Après modification sous `agent/`, exécuter au minimum :

```bash
PYTHONPATH=agent/src python -m unittest discover -s agent/tests -v
PYTHONPATH=agent/src python -m pulsedeck_agent --config agent/config/pulsedeck-agent.example.yml config validate
bash -n agent/scripts/install.sh agent/scripts/update.sh agent/scripts/uninstall.sh agent/scripts/prepare-state.sh
```

Ne pas exécuter automatiquement `makepkg -si`, l'installateur root ou le service systemd pendant une validation de source.

Le payload autonome de `scripts/deploy_hub.sh` est dérivé des sources runtime du dépôt. Après toute modification sous `hub/`, de `config/pulsedeck.example.toml`, des unités `systemd/`, de `scripts/pulsedeck.sh` ou de `scripts/pulsedeck-updater.sh`, contrôler sa cohérence avec :

```bash
python scripts/sync_deploy_payload.py --check
```

S'il est obsolète, le régénérer puis recontrôler :

```bash
python scripts/sync_deploy_payload.py --write
python scripts/sync_deploy_payload.py --check
```

Le générateur ne doit modifier que la section payload de `scripts/deploy_hub.sh`. Une release stable doit refuser de se construire si ce contrôle échoue. Le launcher d'update reconstruit également le payload depuis le SHA GitHub résolu avant déploiement afin d'éviter qu'un artefact embarqué ancien soit installé silencieusement.

Les critères fonctionnels V1 documentés sont notamment : liaison Pi ↔ ESP32 stable, reprise MQTT, retained messages, cache local, états `fresh / stale / offline`, une application complète, navigation fluide, première animation et stabilité mémoire sur plusieurs heures. Les procédures et commandes permettant de les vérifier restent à définir dans le projet.

Chaque commande future conserve son scope et son mode (`default`, `targeted`, `explicit_only`, `external_or_live`).
Sur échec obligatoire : arrêter, rapporter, ne pas réparer opportunément.

## Diagnostics
Utiliser `diagnostics/patch_XXXX/` pour les preuves utiles demandées par le patch ou la politique projet.
Aucune source runtime ou sortie diagnostique applicative obligatoire n'est définie à ce stade.

Ne jamais y publier automatiquement secrets, caches, dumps, données utilisateur ou logs sans rapport avec le patch.

## Git
Aucun commit/push/reset/clean/restore/stash sans instruction explicite. Préserver les modifications préexistantes hors périmètre. Git reste indépendant de Drive.

## Mode patch
Pour appliquer un ZIP, suivre `codex-patch-mode.md`.
