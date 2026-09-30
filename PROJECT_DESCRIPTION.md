# New project — Raspberry Pi Hub + MQTT + ESP32-4848S040C_I

**English is the authoritative project documentation language.** French mirror: [`PROJECT_DESCRIPTION.fr.md`](PROJECT_DESCRIPTION.fr.md).

## 1. PulseMon closure

PulseMon remains on its current architecture and is not being refactored into a multi-application platform.

Closure state:
- working ESP32-S3 firmware;
- autonomous NTP;
- validated network sequence;
- Weather, News, Printer, then PC backend initialized in that order;
- PC backend state machine `UNKNOWN / ONLINE / SUSPECT / OFFLINE`;
- delay before OFFLINE to absorb short slowdowns;
- Main/GPU locked while the PC backend is unavailable;
- automatic recovery when the backend becomes available again;
- additional hardware scenarios completed: short outage, offline navigation and boot with the PC powered off.

PulseMon therefore remains the existing stable base. Architecture experiments, LVGL 9 work and richer applications are developed in this separate project.

---

## 2. Project objective

Build an extensible home information display around three components:

```text
Raspberry Pi = collection / normalization / aggregation
MQTT         = data bus
ESP32-S3     = graphical interface
```

Target display hardware: `ESP32-4848S040C_I`, 4-inch 480 × 480 screen, with an interface designed for LVGL 9 from the start.

Main goals:
- multiple applications;
- multiple data sources;
- rich UI;
- animations;
- graphs;
- fluid navigation;
- low network complexity on the ESP32;
- add applications without reimplementing HTTP/TLS/API logic on the ESP32.

---

## 3. Target architecture

```text
PC gamer ──PulseDeck Agent──┐
Mini-server ─PulseDeck Agent──┼───────────┐
                              │           ▼
                        Raspberry Pi
                ┌──────────────────────────┐
Internet ──────►│ Weather collector        │
                │ News collector           │
Agents ────────►│ Machine metrics          │
Printer ───────►│ Printer collector/bridge │
LAN ───────────►│ Network collectors       │
                │                          │
                │      hub service         │
                │          │               │
                │      Mosquitto           │
                └──────────┬───────────────┘
                           │
                           │ MQTT
                           ▼
                ┌──────────────────────────┐
                │ ESP32-4848S040C_I        │
                │                          │
                │ Wi-Fi                    │
                │ MQTT                     │
                │ local NTP                │
                │ local cache              │
                │ fresh/stale/offline      │
                │ LVGL 9                   │
                │ apps / widgets / graphs  │
                │ animations               │
                └──────────────────────────┘
```

Core principle: the Pi remains the central collector/normalizer and MQTT publisher; machine-local agents only collect their host metrics. The ESP32 renders, animates, caches and manages user interaction.


### PulseDeck Agent V1

Machine-local PC/server metrics are collected by a common PulseDeck Agent codebase. The agent is not a replacement for the Raspberry Pi hub: it collects local metrics and sends them to the Pi; the Pi remains responsible for source orchestration, normalization and display-oriented MQTT publication.

Locked V1 modules:

```text
mandatory  CPU + MEMORY + NETWORK
optional   GPU
```

Initial deployment profiles:

```text
mini-server  = CPU + MEMORY + NETWORK
PC gamer     = CPU + MEMORY + NETWORK + GPU
```

Locked V1 metric scope:
- CPU: usage, temperature and power when available;
- MEMORY: used bytes, total bytes and utilization percentage;
- NETWORK: configured interface, RX/TX throughput and RX/TX byte counters;
- GPU when enabled: usage, temperature, power, core clock, memory clock, VRAM used/total and fan telemetry when available.

The network collector targets the interface selected by YAML configuration so container/bridge interfaces are not implicitly aggregated; `auto` resolves the default-route interface when possible. GPU enablement is configuration-driven. Agent configuration is YAML at `/etc/pulsedeck-agent/agent.yml`, systemd supervises the runtime, Arch/pacman installation uses `makepkg` through a clean temporary checkout of the selected remote channel pinned to an exact Git revision; the Arch installer authenticates sudo once, builds without delegating installation to makepkg, then installs the resulting package explicitly and non-interactively with pacman. The standalone installer uses the same `agent/` sources but is restricted to non-Arch Linux systems and refuses Arch/pacman hosts, and `pulsedeck-agent update` is the common same-channel update command. From `patch_0021`, Agent-to-Pi transport V1 is read-only HTTP on the trusted LAN. The Agent exposes `GET /v1/snapshot` on a configurable bind address and port (default `8765`); the Pi polls a configurable host/IP and port. No monitored-machine IP is hardcoded. The HTTP endpoint is unauthenticated in the current trusted-LAN V1 scope and must not be exposed directly to the Internet.

The first Agent deployment target is the mini-server with CPU + MEMORY + NETWORK. The PC gamer uses the same agent with GPU enabled. `agent-002` maintains a local diagnostic snapshot under `/var/lib/pulsedeck-agent/snapshot.json`. `patch_0021` does not fetch that file: it defines a separate HTTP wire envelope (`schema=1`, `protocol=pulsedeck-agent-http`, response timestamp, `snapshot`) and validates snapshot age/health on the Pi before normalization.

---

## 4. Raspberry Pi

The Pi is the global backend for the system.

Reference platform observed at project start:
- Raspberry Pi 3 Model B Plus Rev 1.3;
- Arch Linux ARM rolling;
- `armv7l` architecture;
- observed kernel `6.18.33-4-rpi`;
- observed Python `3.14.5`;
- about 1 GiB RAM;
- microSD as primary storage;
- IPv6 disabled on `bluebox` by user choice.

V1 foundation:

```text
native Mosquitto
+
one Python application service "pulsedeck-hub"
+
systemd / journald
```

The hub administration interface is implemented inside the same application service with FastAPI/Uvicorn and lightweight HTML. Application configuration uses TOML. Remote-service secrets remain separate from versioned configuration. Normal collector configuration is performed through PulseDeck Admin.

Runtime layout established from `patch_0003`:
- system user `pulsedeck`;
- application under `/opt/pulsedeck`;
- configuration at `/etc/pulsedeck/pulsedeck.toml`;
- runtime state under `/var/lib/pulsedeck`;
- dedicated Python environment at `/opt/pulsedeck/venv`;
- standalone deployment without a repository clone on the Pi.

The first hub service maintains `pulsedeck/v1/system/availability` with retained QoS 1, MQTT Last Will and automatic reconnect. This runtime was deployed and validated on `bluebox` on 2026-09-27: systemd service active and a retained `schema=1/state=online` payload observed.

Raspberry Pi deployment uses a one-time `scripts/install.sh` bootstrap, a persistent master launcher and three worker scripts. On a fresh target, `install.sh` downloads and syntax-validates `pulsedeck.sh`, installs it as `/usr/local/sbin/pulsedeck`, seeds the installer cache and delegates the complete installation to it. From then on, `/usr/local/sbin/pulsedeck` is the only normal operational entry point. It refreshes `pulsedeck.sh`, `setup_pi.sh`, `bootstrap_pi.sh` and `deploy_hub.sh` from the selected Git ref, validates shell syntax, updates only changed cached copies under `/var/lib/pulsedeck/installer/scripts/`, then invokes the refreshed `setup_pi.sh`. `bootstrap_pi.sh` manages the system/Mosquitto foundation and `deploy_hub.sh` manages the application service. Deterministic steps are automatic. The scripts install and repair the technical foundation; API keys, filters and collector-specific settings are configured in PulseDeck Admin.

From `patch_0007`, Weather is the first active collector and uses OpenWeather One Call API 4.0. The hub uses `current`, `timeline/1h` and `timeline/1day`, metric units and French provider localization. V1 cadences are 10 minutes for current, 30 minutes for hourly forecasts and 3 hours for daily forecasts. The OpenWeather key is stored separately in `/etc/pulsedeck/secrets/openweather_api_key` and is never placed in versioned configuration. Since `patch_0008`, Weather is configured and tested in PulseDeck Admin, which reloads the collector without a manual service restart.

From `patch_0010-1`, News uses NewsAPI v2. Provider calls are HTTPS-only and the key is sent only in the `X-Api-Key` header, never in the query string. From `patch_0012`, the Admin/provider contract follows endpoint-specific NewsAPI parameters: `top-headlines` supports `q`, `sources`, `country` and `category` with the documented `sources` exclusivity rule, while `everything` supports `q`, `searchIn`, `sources`, `domains`, `excludeDomains`, `from`, `to`, `language` and `sortBy`. PulseDeck fixes `page=1` for the current display snapshot and maps `max_articles` to `pageSize`. The hub publishes retained QoS 1 snapshots on `news/availability` and `news/latest` and preserves the last valid snapshot after provider failures. The NewsAPI key is stored at `/etc/pulsedeck/secrets/newsapi_api_key`. From `patch_0013`, News also supports GNews v4 as a selectable provider. GNews uses `top-headlines` or `search`, HTTPS and `X-Api-Key`; `search` requires `q` (maximum 200 characters), and the Admin exposes GNews-specific language/country/category/search-field/nullable/date/sort controls. NewsAPI and GNews keys are stored independently at `/etc/pulsedeck/secrets/newsapi_api_key` and `/etc/pulsedeck/secrets/gnews_api_key`. Both providers normalize into the same News MQTT schema.

Avoid microservices, containers and infrastructure dependencies that are not needed initially.

Initial structure:

```text
hub/
├── pyproject.toml
└── src/pulsedeck_hub/
    ├── collectors/
    ├── mqtt/
    ├── health/
    ├── admin/
    ├── config.py
    ├── logging_setup.py
    └── main.py

config/
docs/pi/
scripts/
systemd/
```

Pi responsibilities:
- Internet API calls;
- HTTPS/TLS to remote services;
- API-key management;
- persistent connections;
- proprietary protocols;
- Weather, News, Printer and configurable monitored-machine collection;
- data normalization;
- cache;
- MQTT publication;
- source availability;
- lightweight administration API and Web UI.

---

## 5. ESP32-4848S040C_I

The ESP32 firmware is interface-centric rather than Internet-collection-centric.

Responsibilities:

```text
Wi-Fi
MQTT
NTP
local cache
data state
navigation
LVGL 9
widgets
graphs
animations
touch interaction
```

The ESP32 remains autonomous for:
- time;
- interface;
- navigation;
- rendering;
- display of the last valid data.

Loss of the Pi or MQTT must not make the interface unusable.

---

## 6. MQTT contract

The V1 broker is Mosquitto, available only on the IPv4 LAN over TCP `1883`. It is never exposed directly to the Internet. For the current trusted home-LAN scope, V1 uses no MQTT authentication, ACLs or TLS. This model must be revisited if the network scope changes or MQTT later carries sensitive commands.

The versioned namespace is `pulsedeck/v1/...`.

Initial topics:

```text
pulsedeck/v1/system/availability

pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily

pulsedeck/v1/news/availability
pulsedeck/v1/news/latest

pulsedeck/v1/printer/<id>/availability
pulsedeck/v1/printer/<id>/status
pulsedeck/v1/printer/<id>/job
pulsedeck/v1/printer/<id>/thumbnail

pulsedeck/v1/machine/<id>/availability
pulsedeck/v1/machine/<id>/dashboard
```

From `patch_0022`, monitored PCs and servers form a configurable fleet under `[collectors.machines]` and repeated `[[collectors.machines.devices]]` tables. Each entry has a stable logical `id`, display `name`, user-configured `host`, `port` and enabled state. `192.168.0.1` remains example input only; no monitored-machine address is compiled into the hub. The Pi polls each enabled PulseDeck Agent over read-only HTTP (`GET /v1/snapshot`, default TCP `8765`), validates freshness/health, normalizes the Agent wire payload and publishes retained QoS 1 schema 1 under `machine/<id>/availability` and `machine/<id>/dashboard`. CPU, memory and network are mandatory Agent capabilities; GPU data is normalized when the Agent advertises it.

V1 QoS policy:
- QoS 1 for state, availability and application snapshots;
- QoS 0 for optional fast ephemeral streams;
- QoS 2 unused.

Payloads must be:
- stable;
- versioned;
- simple to parse;
- already normalized;
- display-oriented;
- timestamped.

Exact JSON schemas are defined application by application before implementation. Weather (`patch_0007`), News (`patch_0010-1`) and Machines (`patch_0022`) have schema 1 contracts fixed in the hub.

Example:

```json
{
  "ts": 1790335000,
  "online": true,
  "data": {
    "temp": 18.6,
    "humidity": 72,
    "pressure": 1017
  }
}
```

---

## 7. Retained messages and availability

Use MQTT features to speed recovery:
- retained messages for last known states;
- Last Will for availability;
- automatic reconnect;
- immediate resynchronization after reboot.

Retained availability topics:

```text
pulsedeck/v1/system/availability
pulsedeck/v1/weather/availability
pulsedeck/v1/news/availability
pulsedeck/v1/machine/<id>/availability
pulsedeck/v1/printer/availability
```

The ESP32 also derives a local data-age state:

```text
fresh
stale
offline
```

---

## 8. ESP32 firmware architecture

Planned organization:

```text
src/
├── apps/
│   ├── home/
│   ├── weather/
│   ├── printer/
│   ├── pc/
│   └── network/
│
├── services/
│   ├── mqtt/
│   ├── time/
│   ├── settings/
│   └── storage/
│
├── models/
│
├── ui/
│   ├── navigation/
│   ├── widgets/
│   ├── graphs/
│   └── theme/
│
└── main/
```

Each application should mainly contain:
- its data model;
- MQTT subscriptions;
- display logic;
- LVGL widgets.

It must not reimplement HTTP, TLS, remote authentication or proprietary protocols.

---

## 9. UI and animations

The new project may use more ESP32-S3 resources for rendering.

Goals:
- smooth transitions;
- animated widgets;
- graphs;
- gauges;
- animated weather icons;
- animated Printer progress;
- visual online/offline states;
- multiple pages per application.

Initial rules:
- short animations;
- redraw only useful areas;
- reasonable target of 15 to 30 FPS;
- measure rendering and flush times;
- monitor PSRAM, internal heap, DMA and task stacks.

---

## 10. Planned applications

### Home

Summary view:
- time;
- weather;
- PC;
- Printer;
- network;
- important notifications.

### Weather

V1 provider: OpenWeather One Call API 4.0. The Raspberry Pi publishes normalized snapshots on `weather/current`, `weather/hourly` and `weather/daily`, plus separate `weather/availability`. Provider errors do not delete the last valid retained snapshots.

Possible pages:
- current weather;
- hourly forecast;
- daily forecast;
- rain;
- wind;
- humidity;
- pressure;
- sunrise/sunset;
- graphs.

### News

V1 News providers: NewsAPI v2 and GNews v4. The active provider is selected in PulseDeck Admin. NewsAPI uses `top-headlines` / `everything`; GNews uses `top-headlines` / `search`. Both use HTTPS with `X-Api-Key`, provider-specific fields are exposed dynamically, pagination is fixed to page 1 for the current snapshot, and both responses normalize to retained `news/latest` plus `news/availability`. Long provider `content` is deliberately not republished so the ESP32 payload stays compact.

### Printer

The Pi keeps print information current during a job:
- state;
- progress;
- layer;
- elapsed time;
- remaining time;
- estimated finish time;
- thumbnail;
- temperatures when available;
- short job history.

When the user returns to the Printer screen, recent data is already available to the ESP32.

### Monitored machines

Machine metrics are supplied to the Pi by PulseDeck Agent instances. The same Agent codebase serves every monitored PC/server. The initial deployment profiles remain useful examples rather than fixed application slots:
- mini-server: CPU + MEMORY + NETWORK;
- PC gamer: CPU + MEMORY + NETWORK + GPU.

From `patch_0022`, PulseDeck Admin manages the machine fleet using the same device-list model as Printer: add, edit, test, enable/disable and remove a machine without changing hub code. The Pi owns normalized application state and MQTT publication, polls each configured Agent independently, preserves unavailable optional telemetry as `null`, and publishes retained QoS 1 under `machine/<id>/availability` plus `machine/<id>/dashboard`. Poll cadence, timeout, consecutive-failure threshold and maximum snapshot age are fleet settings. Removing a machine clears its retained machine topics.

Dashboard data can include:
- CPU;
- RAM;
- network;
- GPU when enabled;
- temperatures;
- clocks where applicable;
- power where available;
- short history.

### Network

Possible data:
- Internet;
- Raspberry Pi;
- MQTT broker;
- latency;
- Wi-Fi/RSSI;
- IP/gateway;
- LAN services;
- NAS;
- Home Assistant;
- other equipment.

---

## 11. Principles to preserve

1. The ESP32 is an intelligent graphical terminal, not an Internet API aggregator.
2. The Pi centralizes protocols, secrets and collectors.
3. MQTT is the primary data bus.
4. Data is normalized before publication.
5. Contracts are versioned.
6. The ESP32 keeps autonomous NTP.
7. Last valid data remains visible when the Pi is lost.
8. Old data is explicitly `stale`.
9. Applications do not recreate their own network stacks.
10. Heavy processing stays on the Pi when appropriate.
11. The UI is independent of actual collection frequency.
12. New apps should be addable without modifying existing apps.
13. User and operational documentation is maintained in English and French; English is authoritative.

---

## 12. Development plan

### Phase 0 — Hardware bring-up

Validate:
- ESP32-4848S040C_I;
- ST7701 display;
- touch;
- PSRAM;
- Wi-Fi;
- LVGL 9;
- RGB timings;
- 480 × 480 rendering;
- framebuffer stability.

### Phase 1 — Pi infrastructure

Install:
- Mosquitto;
- minimal hub service;
- configuration;
- logs;
- test-topic publication.

### Phase 2 — Minimal MQTT firmware

ESP32:
- Wi-Fi;
- NTP;
- MQTT;
- reconnect;
- retained messages;
- MQTT diagnostics screen.

### Phase 3 — First application

Weather is the reference application. `patch_0007` implements the Pi collector and Weather MQTT V1 contract with OpenWeather One Call 4.0. Remaining ESP32 work:
- ESP cache;
- first LVGL 9 screen;
- first animation;
- end-to-end validation of the application model.

### Phase 4 — News

Integrate the reference News feed:
- selectable NewsAPI v2 / GNews v4 provider;
- HTTPS;
- `X-Api-Key` authentication;
- provider-specific endpoints and filters;
- normalized retained MQTT snapshot;
- PulseDeck Admin configuration.

### Phase 5 — Printer

Move progressively to the Pi:
- persistent connection;
- job tracking;
- thumbnail;
- normalized MQTT status.

### Phase 6 — Machine agents

Deploy and validate PulseDeck Agent, then integrate machine metrics through the Raspberry Pi:
- validate `agent-002` local collection, YAML configuration, systemd service and installation/update paths on the mini-server;
- second deployment on the PC gamer with CPU + MEMORY + NETWORK + GPU;
- validate the Agent HTTP transport end to end on more than one configured machine;
- validate dynamic `machine/<id>/...` MQTT schema 1, including optional GPU telemetry;
- manage add/edit/test/enable/disable/remove operations from PulseDeck Admin;
- normalize machine state on the Pi before MQTT publication and expose per-machine online/offline availability plus dashboard data.

### Phase 7 — Advanced UI

Add:
- animations;
- shared widgets;
- graphs;
- themes;
- transitions;
- Home screen.

### Phase 8 — Additional applications

Add new apps only after the MQTT/UI foundation is stable.

---

## 13. Decisions still required

Define before full implementation:
- exact payload schemas outside Weather, News and Machines;
- cache policy;
- collector cadences for future/unimplemented collectors that do not yet have their own contract;
- ESP-IDF version;
- exact LVGL 9 version;
- ST7701 driver;
- touch driver;
- whether EEZ Studio is used;
- OTA;
- asset/image management.

---

## 14. Out of scope for V1

Do not complicate V1 with:
- MQTT clustering;
- Kubernetes;
- a heavy database;
- many microservices;
- mandatory cloud services;
- long-term history;
- dynamic plugin systems on the ESP32.

Add these only when a concrete need appears.

---

## 15. V1 objective

Prove the complete chain:

```text
data source
    ↓
Raspberry Pi collector
    ↓
MQTT
    ↓
ESP32
    ↓
local cache
    ↓
LVGL 9
    ↓
480 × 480 display
```

A successful V1 demonstrates:
- stable Pi ↔ ESP32 link;
- recovery after MQTT outage;
- retained messages;
- local cache;
- `fresh/stale/offline` states;
- one complete application;
- smooth navigation;
- a first animation;
- memory stability over several hours.

---

## 16. Final positioning

PulseMon remains the existing stable and functional project.

PulseDeck is a separate platform built around:

```text
Raspberry Pi = data
MQTT         = bus
ESP32-S3     = interface
LVGL 9       = rendering
480 × 480    = new UX
```

This separation preserves PulseMon without regression while opening a much more extensible platform for future applications.
