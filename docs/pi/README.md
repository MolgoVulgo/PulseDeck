# PulseDeck Raspberry Pi Hub

> **Documentation language policy:** English is the primary documentation language. French mirrors live under [`fr/`](fr/). If the two versions differ, the English document is authoritative.

This directory documents the Raspberry Pi implementation. `PROJECT_DESCRIPTION.md` remains the canonical project description and `PROJECT_SCHEMA.md` records shared technical contracts.

## Role

The Raspberry Pi centralizes remote API access, collection, normalization, source health and MQTT publication. The ESP32 receives display-ready data and stays focused on UI, local cache, NTP, navigation and LVGL rendering.

## Reference platform

The validated reference host is a Raspberry Pi 3 Model B Plus running Arch Linux ARM on `armv7l`, Python 3.14, native Mosquitto, systemd and journald. PulseDeck does not require containers.

## V1 foundation

- native Mosquitto on the LAN;
- one Python service: `pulsedeck-hub`;
- FastAPI/Uvicorn Admin UI in the same process;
- TOML runtime configuration;
- service secrets stored separately under `/etc/pulsedeck/secrets/`;
- systemd supervision and journald logs.

## Implemented collectors

- Weather — OpenWeather One Call 4.0;
- News — NewsAPI v2 over HTTPS with `X-Api-Key` authentication.

Planned collectors: PC gamer, mini server and printer.

## Documents

- [`INSTALL.md`](INSTALL.md) — installation and deployment;
- [`OPERATIONS.md`](OPERATIONS.md) — runtime checks and troubleshooting;
- [`MQTT.md`](MQTT.md) — broker and topic contract;
- [`ADMIN.md`](ADMIN.md) — local Web Admin;
- [`WEATHER.md`](WEATHER.md) — Weather V1;
- [`NEWS.md`](NEWS.md) — News V1 / NewsAPI.
