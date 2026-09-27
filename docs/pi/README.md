# PulseDeck — Raspberry Pi Hub

Ce dossier documente l'implémentation Raspberry Pi uniquement. `PROJECT_DESCRIPTION.md` reste la description canonique de l'architecture globale et `PROJECT_SCHEMA.md` le contrat descriptif partagé.

## Rôle

Le Raspberry Pi centralise les accès distants, la collecte, la normalisation, l'état des sources et la publication MQTT. L'ESP32 consomme des données déjà adaptées à l'affichage.

## Plateforme de référence observée

- Raspberry Pi 3 Model B Plus Rev 1.3
- Arch Linux ARM rolling
- `armv7l`
- kernel observé `6.18.33-4-rpi`
- Python observé `3.14.5`
- 917 MiB de RAM
- environ 18 GiB libres sur `/` au relevé initial
- IPv6 désactivé sur `bluebox`

Ces valeurs décrivent la machine de référence au lancement ; elles ne constituent pas toutes des exigences de compatibilité futures.

## Socle V1

- Mosquitto natif
- un seul service applicatif Python `pulsedeck-hub`
- systemd pour la supervision
- journald pour les logs
- FastAPI prévu pour l'administration Web légère
- configuration applicative TOML
- pas de conteneur requis en V1

## Collectors prévus

- Weather
- News
- PC gamer
- Mini serveur
- Printer

Les modules existent dans le squelette, mais leurs contrats fonctionnels ne sont pas définis par `patch_0001`.

## Weather

Le collector Weather V1 utilise OpenWeather One Call 4.0. Voir [`WEATHER.md`](WEATHER.md) pour la configuration, les cadences et les payloads MQTT.
