# Hub Raspberry Pi PulseDeck

> **Politique de langue :** l’anglais est la langue documentaire principale. Les traductions françaises sont regroupées dans ce dossier `fr/`. En cas de divergence, la version anglaise fait référence.

Ce dossier documente l’implémentation Raspberry Pi. `PROJECT_DESCRIPTION.md` reste la description canonique du projet et `PROJECT_SCHEMA.md` consigne les contrats techniques partagés.

## Rôle

Le Raspberry Pi centralise les accès API distants, l’orchestration de la collecte, la normalisation, l’état des sources et la publication MQTT. Les métriques locales des PC/serveurs sont fournies par des instances PulseDeck Agent ; le Pi reste le hub central et porte l’état normalisé destiné à l’affichage. L’ESP32 reçoit des données prêtes à afficher et reste centré sur l’UI, le cache local, NTP, la navigation et le rendu LVGL.

## Plateforme de référence

La cible validée est un Raspberry Pi 3 Model B Plus sous Arch Linux ARM `armv7l`, Python 3.14, Mosquitto natif, systemd et journald. PulseDeck ne nécessite pas de conteneur.

## Socle V1

- Mosquitto natif sur le LAN ;
- un service Python : `pulsedeck-hub` ;
- FastAPI/Uvicorn Admin dans le même processus ;
- configuration runtime TOML ;
- secrets services séparés sous `/etc/pulsedeck/secrets/` ;
- supervision systemd et logs journald.

## Collectors implémentés

- Weather — OpenWeather One Call 4.0 ;
- News — NewsAPI v2 en HTTPS avec authentification `X-Api-Key`.

`agent-002` fournit le premier jet exécutable de PulseDeck Agent : configuration YAML, collecte locale CPU + MEMORY + NETWORK, GPU optionnel, service systemd, packaging Arch `makepkg`, installation standard et `pulsedeck-agent update`. L’intégration machine nécessite encore de définir le transport Agent → Pi. La collecte Printer reste également prévue.

## Documents

- [`../INSTALL.md`](../INSTALL.md) — installation et déploiement ;
- [`../OPERATIONS.md`](../OPERATIONS.md) — exploitation et diagnostic ;
- [`../MQTT.md`](../MQTT.md) — contrat MQTT ;
- [`../ADMIN.md`](../ADMIN.md) — Web Admin local ;
- [`../WEATHER.md`](../WEATHER.md) — Weather V1 ;
- [`../NEWS.md`](../NEWS.md) — News V1 / NewsAPI.
