# PulseDeck

**English documentation is authoritative.** French version: [`README.fr.md`](README.fr.md).

PulseDeck is a modular home information display built around a **Raspberry Pi**, **MQTT** and an **ESP32-S3 480 × 480** display.

The Raspberry Pi centralizes remote API access, data collection and normalization. It publishes simple, versioned, display-ready snapshots over MQTT. The ESP32 stays focused on Wi-Fi/MQTT/NTP, local cache, freshness state, navigation, LVGL 9 rendering and animation.

## Architecture

```text
                         Raspberry Pi
                ┌──────────────────────────┐
Internet ──────►│ Weather / News           │
PC ────────────►│ PC metrics               │
Server ────────►│ Mini-server metrics      │
Printer ───────►│ Printer state            │
                │                          │
                │    pulsedeck-hub         │
                │          │               │
                │      Mosquitto           │
                └──────────┬───────────────┘
                           │ MQTT / LAN
                           ▼
                ┌──────────────────────────┐
                │ ESP32-4848S040C_I        │
                │ Wi-Fi / MQTT / NTP       │
                │ local cache              │
                │ fresh / stale / offline  │
                │ LVGL 9                   │
                └──────────────────────────┘
```

```text
Raspberry Pi = collection / normalization / aggregation
MQTT         = local data bus
ESP32-S3     = user interface
```

## Current Raspberry Pi stack

- Raspberry Pi 3 Model B Plus reference target;
- Arch Linux ARM / `armv7l`;
- Python 3.14;
- native Mosquitto;
- one Python `pulsedeck-hub` process;
- FastAPI/Uvicorn Web Admin inside the hub;
- systemd / journald;
- no container or database required for V1.

## MQTT

PulseDeck V1 uses Mosquitto as a trusted-LAN data bus:

- TCP `1883`;
- LAN IPv4 listener only;
- no direct Internet exposure;
- QoS 1 for states/snapshots;
- QoS 0 for optional fast streams;
- retained last-known snapshots;
- Last Will and automatic reconnect.

Main namespace:

```text
pulsedeck/v1/...
```

Implemented application topics include:

```text
pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily

pulsedeck/v1/news/availability
pulsedeck/v1/news/latest
```

## Weather

Weather V1 uses OpenWeather One Call 4.0. The hub retrieves `current`, `timeline/1h` and `timeline/1day`, normalizes the provider response and publishes retained QoS 1 snapshots.

Default cadence:

```text
current  10 min
hourly   30 min, 48-hour horizon
daily     3 h,   10-day horizon
```

The OpenWeather key is stored separately from TOML in `/etc/pulsedeck/secrets/openweather_api_key` and is managed from PulseDeck Admin.

See [`docs/pi/WEATHER.md`](docs/pi/WEATHER.md).

## News

News V1 uses **GNews API v4** with HTTPS and provider authentication in the HTTP header:

```text
X-Api-Key: <secret>
```

The key is never added to the query string. PulseDeck supports both GNews `top-headlines` and `search` modes, normalizes article metadata, deliberately excludes full provider `content`, then publishes a compact retained snapshot on `pulsedeck/v1/news/latest`.

The GNews secret is stored at `/etc/pulsedeck/secrets/gnews_api_key` and is configured from PulseDeck Admin.

See [`docs/pi/NEWS.md`](docs/pi/NEWS.md).

## PulseDeck Admin

After installation, normal service configuration is done from the Web UI:

```text
http://<Pi-LAN-IPv4>:8080
```

Admin currently provides:

- Hub / MQTT / system health;
- Weather configuration, API test and hot reload;
- News configuration, GNews API test and hot reload;
- common Services catalog for upcoming collectors;
- local administrator password management.

Secrets are masked after storage. Weather and News changes are tested before activation and applied transactionally.

## Raspberry Pi installation

A Git clone is not required on the target.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/setup_pi.sh \
  -o setup_pi.sh

chmod +x setup_pi.sh
./setup_pi.sh --check
sudo ./setup_pi.sh
```

Targeted hub update:

```bash
sudo ./setup_pi.sh --hub-only
```

The installer handles the technical foundation. Collector-specific keys, filters and service settings belong in PulseDeck Admin.

The deployment scripts never perform a global Arch Linux update (`pacman -Sy` / `pacman -Syu`).

## Repository layout

```text
PulseDeck/
├── config/
├── docs/pi/                English operational docs
│   └── fr/                 French mirrors
├── hub/
│   └── src/pulsedeck_hub/
│       ├── admin/
│       ├── collectors/
│       ├── health/
│       └── mqtt/
├── scripts/
├── systemd/
├── README.fr.md
├── PROJECT_DESCRIPTION.md
└── PROJECT_SCHEMA.md
```

## Architecture principles

- Remote APIs, HTTPS, credentials and provider-specific protocols stay on the Raspberry Pi.
- MQTT remains a simple local bus between the backend and the display.
- The ESP32 keeps autonomous NTP, UI and last-valid-data cache.
- A Pi/MQTT outage must not make the local interface unusable.
- MQTT payloads are versioned, normalized and timestamped.
- V1 intentionally avoids Kubernetes, MQTT clustering, a heavy database and a microservice fleet.

## Roadmap

Completed foundation:

1. Raspberry Pi / Mosquitto infrastructure;
2. minimal `pulsedeck-hub` runtime;
3. Weather collector;
4. Web Admin;
5. News / GNews collector.

Next planned integrations:

- PC gamer;
- Printer;
- mini server;
- ESP32 application screens, home dashboard, graphs and animations.

## Documentation

English primary documentation:

- [`docs/pi/`](docs/pi/);
- [`docs/pi/ADMIN.md`](docs/pi/ADMIN.md);
- [`docs/pi/WEATHER.md`](docs/pi/WEATHER.md);
- [`docs/pi/NEWS.md`](docs/pi/NEWS.md);
- [`docs/pi/MQTT.md`](docs/pi/MQTT.md).

French mirrors are available under [`docs/pi/fr/`](docs/pi/fr/).
