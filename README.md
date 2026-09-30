# PulseDeck

**English documentation is authoritative.** French version: [`README.fr.md`](README.fr.md).

PulseDeck is a modular home information display built around a **Raspberry Pi**, **MQTT** and an **ESP32-S3 480 × 480** display.

The Raspberry Pi remains the central hub for remote API access, collection orchestration, normalization and display-oriented MQTT publication. Machine-local PC/server metrics are collected by PulseDeck Agent instances and sent to the Pi. The ESP32 stays focused on Wi-Fi/MQTT/NTP, local cache, freshness state, navigation, LVGL 9 rendering and animation.

## Architecture

```text
PC gamer ──PulseDeck Agent──┐
Mini-server ─PulseDeck Agent──┼───────────┐
                              │           ▼
                         Raspberry Pi
                ┌──────────────────────────┐
Internet ──────►│ Weather / News           │
Agents ────────►│ machine metrics          │
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

## PulseDeck Agent V1

PulseDeck Agent is the machine-local metrics component used by monitored PCs and servers. It does not replace the Raspberry Pi hub: the agent collects local machine metrics and sends them to the Pi, while the Pi remains responsible for normalization and display-oriented MQTT publication.

The V1 module contract is locked as follows:

```text
mandatory  CPU + MEMORY + NETWORK
optional   GPU
```

Initial profiles:

```text
mini-server  = CPU + MEMORY + NETWORK
PC gamer     = CPU + MEMORY + NETWORK + GPU
```

V1 metrics:

- CPU: usage, temperature and power when available;
- MEMORY: used bytes, total bytes and utilization percentage;
- NETWORK: configured interface, RX/TX throughput and RX/TX byte counters;
- GPU when enabled: usage, temperature, power, core/memory clocks, VRAM used/total and fan telemetry when available.

The same agent codebase is used on both machines. GPU activation is configuration-driven. Runtime configuration is YAML at `/etc/pulsedeck-agent/agent.yml`; systemd is the service manager; Arch/pacman installation uses `makepkg` through a clean, channel-aware installer that pins the remote Git revision, ignores local checkout changes, authenticates sudo once and installs the built package non-interactively with pacman; the standalone source installer is restricted to non-Arch Linux systems and refuses Arch/pacman hosts; normal updates use `pulsedeck-agent update` on the installed channel. The exact Agent-to-Pi transport and wire payload schema remain unresolved.

See [`agent/README.md`](agent/README.md) and [`agent/docs/INSTALL.md`](agent/docs/INSTALL.md).

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

News V1 supports **NewsAPI v2** and **GNews v4**. Both providers are called over HTTPS and PulseDeck sends their API key only through the HTTP header:

```text
X-Api-Key: <secret>
```

The provider is selected in PulseDeck Admin. NewsAPI supports `top-headlines` / `everything`; GNews supports `top-headlines` / `search`. Provider-specific filters are shown dynamically, while both responses are normalized to the same retained MQTT schema on `pulsedeck/v1/news/latest`. Long provider `content` is deliberately not republished.

Secrets are kept independently at `/etc/pulsedeck/secrets/newsapi_api_key` and `/etc/pulsedeck/secrets/gnews_api_key`; switching provider does not overwrite the other key.

See [`docs/pi/NEWS.md`](docs/pi/NEWS.md).

## PulseDeck Admin

After installation, normal service configuration is done from the Web UI:

```text
http://<Pi-LAN-IPv4>:8080
```

Admin currently provides:

- Hub / MQTT / system health;
- Weather configuration, API test and hot reload;
- News provider selection (NewsAPI / GNews), provider-aware filters, API test and hot reload;
- common Services catalog for upcoming collectors;
- local administrator password management.

Secrets are masked after storage. Weather and News changes are tested before activation and applied transactionally.

## Raspberry Pi installation

A Git clone is not required on the target. A fresh target has a single bootstrap command:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/install.sh \
  | sudo bash
```

`install.sh` downloads and validates only the persistent master launcher, installs it as `/usr/local/sbin/pulsedeck`, seeds the installer cache, then immediately delegates the complete installation to that master command. `setup_pi.sh` is an internal worker and is no longer part of the normal user workflow.

Normal checks and upgrades use:

```bash
pulsedeck --check
sudo pulsedeck
sudo pulsedeck --hub-only
```

The master launcher refreshes `pulsedeck.sh`, `setup_pi.sh`, `bootstrap_pi.sh` and `deploy_hub.sh` from the selected Git ref, validates shell syntax, and replaces only changed cached copies before invoking the refreshed setup worker. Manual re-downloads of `setup_pi.sh` are therefore not part of the normal update flow.

The installer handles the technical foundation. Collector-specific keys, filters and service settings belong in PulseDeck Admin. The deployment scripts never perform a global Arch Linux update (`pacman -Sy` / `pacman -Syu`).

## Repository layout

```text
PulseDeck/
├── agent/                  machine-local PulseDeck Agent
│   ├── config/
│   ├── docs/
│   ├── packaging/arch/
│   ├── scripts/
│   ├── systemd/
│   └── src/pulsedeck_agent/
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
- PulseDeck Agent collects only machine-local metrics; the Raspberry Pi remains the central normalization and MQTT publication point.
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
5. News collector with selectable NewsAPI / GNews provider.

Next planned integrations:

- deploy and validate the first PulseDeck Agent runtime on the mini-server, then on the PC gamer;
- connect both agents to Raspberry Pi collectors and define their normalized MQTT contracts;
- Printer;
- ESP32 application screens, home dashboard, graphs and animations.

## Documentation

English primary documentation:

- [`agent/README.md`](agent/README.md);
- [`agent/docs/INSTALL.md`](agent/docs/INSTALL.md);
- [`docs/pi/`](docs/pi/);
- [`docs/pi/ADMIN.md`](docs/pi/ADMIN.md);
- [`docs/pi/WEATHER.md`](docs/pi/WEATHER.md);
- [`docs/pi/NEWS.md`](docs/pi/NEWS.md);
- [`docs/pi/MQTT.md`](docs/pi/MQTT.md).

French mirrors are available under [`docs/pi/fr/`](docs/pi/fr/).
