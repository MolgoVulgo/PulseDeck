# AGENTS.md — PulseDeck

> Instructions locales réservées à Codex. Ce document ne constitue pas une instruction pour ChatGPT Web.

## Projet
- Nom : `PulseDeck`
- Description : plateforme d'affichage domestique extensible séparant collecte/normalisation sur Raspberry Pi, transport MQTT et interface graphique sur ESP32-S3.
- Stack : Raspberry Pi + MQTT + ESP32-S3 / ESP32-4848S040C_I + LVGL 9. OS Pi, langage du hub, versions exactes et drivers restent `À DÉFINIR`.

Le dépôt local est la source de vérité locale pour Codex. Drive est publication/transport uniquement.

## Architecture active
Le Raspberry Pi porte la collecte, les protocoles distants, la normalisation et la publication des données. MQTT est le bus principal. L'ESP32 porte l'interface, le cache local, les états de fraîcheur, la navigation, le rendu et l'interaction.

Documentation canonique :
- `PROJECT_DESCRIPTION.md` — source canonique détaillée du projet.
- `PROJECT_SCHEMA.md` — contrat descriptif partagé Web/Codex.

Ne pas dupliquer ici les détails déjà maintenus dans une documentation canonique : les référencer.

## Contrats critiques
### Frontières d'architecture
- Le Pi centralise la collecte, les accès API/HTTPS/TLS distants, les protocoles propriétaires et la normalisation.
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
- `PROJECT_DESCRIPTION.md`, `PROJECT_SCHEMA.md`, `AGENTS.md`, `codex-patch-mode.md`, `sync-drive.sh`, `sync-drive.conf`, `sync-drive.filter`.

Générés :
- `REPO_INDEX.json` uniquement pour l'index de publication ; hors baseline source.

Runtime / temporaires :
- `À DÉFINIR` pour l'application. Ne pas inventer de chemins.
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
Aucune commande de build, test ou lint n'est documentée au moment de l'initialisation : ne pas en inventer.

Les critères fonctionnels V1 documentés sont notamment : liaison Pi ↔ ESP32 stable, reprise MQTT, retained messages, cache local, états `fresh/stale/offline`, une application complète, navigation fluide, première animation et stabilité mémoire sur plusieurs heures. Les procédures et commandes permettant de les vérifier restent à définir dans le projet.

Chaque commande future conserve son scope et son mode (`default`, `targeted`, `explicit_only`, `external_or_live`).
Ne jamais installer ou mettre à jour automatiquement des dépendances.
Sur échec obligatoire : arrêter, rapporter, ne pas réparer opportunément.

## Diagnostics
Utiliser `diagnostics/patch_XXXX/` pour les preuves utiles demandées par le patch ou la politique projet.
Aucune source runtime ou sortie diagnostique applicative obligatoire n'est définie à ce stade.

Ne jamais y publier automatiquement secrets, caches, dumps, données utilisateur ou logs sans rapport avec le patch.

## Git
Aucun commit/push/reset/clean/restore/stash sans instruction explicite. Préserver les modifications préexistantes hors périmètre. Git reste indépendant de Drive.

## Mode patch
Pour appliquer un ZIP, suivre `codex-patch-mode.md`.
