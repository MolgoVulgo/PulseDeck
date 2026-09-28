# PROJECT_SCHEMA.md — PulseDeck

**English is authoritative.** French mirror: [`PROJECT_SCHEMA.fr.md`](PROJECT_SCHEMA.fr.md).

```yaml
project:
  name: "PulseDeck"
  slug: "PulseDeck"
  description: "Extensible home display platform: Raspberry Pi for collection/normalization, MQTT as data bus, ESP32-S3 as the LVGL 9 graphical interface."
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
  modules:
    - "Raspberry Pi: collection, normalization, aggregation, cache and data publication"
    - "MQTT: primary data bus between backend and ESP32"
    - "ESP32-S3: Wi-Fi, MQTT, local NTP, local cache, freshness state and LVGL UI"
  documentation_dirs:
    - "docs/pi"
    - "docs/pi/fr"

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
    - "CREATE was initialized from the canonical user-provided project description; no local application code had been inspected at initialization."
    - "The target Drive folder was empty before transport zones were created."
    - "Pi platform observed on 2026-09-27: Raspberry Pi 3 Model B Plus Rev 1.3, Arch Linux ARM armv7l, kernel 6.18.33-4-rpi, Python 3.14.5, 917 MiB RAM, about 18 GiB free on root."
    - "IPv6 was disabled on bluebox by user choice."
    - "A later full deployment on 2026-09-27 observed a global IPv6 address again; Mosquitto remained bound only to 192.168.0.250:1883 on IPv4."
    - "MQTT bootstrap executed on bluebox on 2026-09-27: Mosquitto 2.1.2-2 installed, single listener 192.168.0.250:1883, QoS 1 retained and retained restoration after restart validated, zero failures; no-swap warning accepted."
    - "Application hub deployed on bluebox on 2026-09-27: venv created, paho-mqtt 2.1.0 and pulsedeck-hub 0.1.0 installed, systemd service active/enabled, retained pulsedeck/v1/system/availability observed with schema=1 and state=online."
  documented:
    - "The Raspberry Pi collects, normalizes and aggregates data; the ESP32 renders, animates, caches and manages interaction."
    - "MQTT is the primary data bus."
    - "The target ESP32 is ESP32-4848S040C_I with a 480 x 480 display and an interface designed for LVGL 9."
    - "The ESP32 keeps autonomous NTP, interface, navigation, rendering and last valid data if the Pi or MQTT is lost."
    - "MQTT data is stable, versioned, normalized, easy to parse, display-oriented and timestamped."
    - "The MQTT contract uses retained messages, Last Will, automatic reconnect and resynchronization after reboot."
    - "Local freshness states are fresh, stale and offline."
    - "An ESP32 application must not reimplement HTTP, TLS, remote authentication or proprietary protocols."
    - "V1 demonstrates source -> Raspberry Pi collector -> MQTT -> ESP32 -> local cache -> LVGL 9 -> 480 x 480 display."
    - "V1 excludes MQTT clustering, Kubernetes, a heavy database, many microservices, mandatory cloud services, long-term history and a dynamic ESP32 plugin system."
  confirmed:
    - "Project name: PulseDeck."
    - "Planned local root: /home/kaj/Projets/PulseDeck/."
    - "Physical Drive destination: folder ID 1EgquPKEO5GjlMZ6ZQccmnFlgqY6THjbr."
    - "rclone remote: gdrive."
    - "Logical rclone path: PulseDeck."
    - "Raspberry Pi V1 OS: Arch Linux ARM rolling on armv7l."
    - "Hub language: Python 3; observed runtime Python 3.14.5."
    - "MQTT V1 broker: native Mosquitto, TCP 1883, IPv4 LAN only, never directly exposed to the Internet."
    - "MQTT V1 has no authentication, ACL or TLS within the current trusted home LAN scope."
    - "MQTT V1 namespace: pulsedeck/v1/."
    - "MQTT V1 QoS: QoS 1 for states/snapshots, QoS 0 for optional fast streams, QoS 2 unused."
    - "V1 state and availability topics are retained; optional fast streams are not retained."
    - "Application configuration uses TOML; secrets stay separate from versioned files."
    - "Supervision: systemd; logs: journald."
    - "Administration is implemented inside the hub with FastAPI and lightweight HTML on the Pi LAN IPv4, port 8080."
    - "Hub runtime: /opt/pulsedeck for application/venv, /etc/pulsedeck/pulsedeck.toml for config, /var/lib/pulsedeck for state."
    - "Hub systemd user: pulsedeck."
    - "Python MQTT dependency: paho-mqtt >=2.1,<3 using MQTT 3.1.1."
    - "Hub deployment is supported through standalone scripts/deploy_hub.sh without a repository clone on the Pi."
    - "pulsedeck/v1/system/availability schema 1 was defined and implemented in patch_0003."
    - "MQTT foundation was live-validated on bluebox on 2026-09-27: Mosquitto active/enabled, single LAN IPv4 listener, retained persistence operational."
    - "scripts/setup_pi.sh is the complete installer orchestrator: MQTT bootstrap followed by hub deployment."
    - "setup_pi.sh can run without a clone and downloads specialized scripts from GitHub when absent locally."
    - "From patch_0010-1, /usr/local/sbin/pulsedeck is the persistent master launcher: it refreshes pulsedeck.sh, setup_pi.sh, bootstrap_pi.sh and deploy_hub.sh from the selected Git ref, validates shell syntax, updates only changed cached copies under /var/lib/pulsedeck/installer/scripts, then executes the refreshed setup worker."
    - "From patch_0011, scripts/install.sh is the only first-install bootstrap: it downloads and syntax-validates pulsedeck.sh, installs /usr/local/sbin/pulsedeck, seeds the installer cache, then delegates the complete installation to the persistent master launcher."
    - "Deployment scripts automate deterministic operations and only ask for information that cannot safely be derived."
    - "--non-interactive forbids questions and turns an unavoidable manual decision into an explicit failure."
    - "PulseDeck Admin V1 uses local password authentication, signed sessions, HttpOnly/SameSite=Strict cookies and remains LAN-only; V1 HTTP must not be exposed to the Internet."
    - "Weather changes from the UI are provider-tested before save and reload the collector in-process without a manual systemd restart."
    - "Weather V1 uses OpenWeather One Call API 4.0 endpoints current, timeline/1h and timeline/1day."
    - "Weather V1 publishes retained QoS 1 schema 1 on weather/availability, weather/current, weather/hourly and weather/daily."
    - "Weather V1 cadence: current 600 s, hourly 1800 s, daily 10800 s; horizon 48 hourly records and 10 daily records."
    - "The OpenWeather runtime key is outside TOML at /etc/pulsedeck/secrets/openweather_api_key; root and the pulsedeck service can update it for Web configuration."
    - "From patch_0008, scripts install the technical foundation without service-specific questions; Weather is configured in PulseDeck Admin."
    - "From patch_0009, PulseDeck Admin has Dashboard / Weather / Services / Security navigation, uniform notifications and a common service catalog."
    - "Development order after the Admin framework: News, gaming PC, Printer."
    - "News V1 uses NewsAPI v2 over HTTPS only, with provider authentication sent only in X-Api-Key."
    - "News V1 supports NewsAPI top-headlines and everything with endpoint-specific provider fields; q is optional, sources is supported in both modes, and advanced everything filters include searchIn/domains/excludeDomains/from/to/language/sortBy."
    - "News V1 defaults: top-headlines, country=fr, no category restriction, max_articles/pageSize=10, interval=1800 s; configurable in PulseDeck Admin."
    - "News V1 publishes retained QoS 1 schema 1 on news/availability and news/latest; provider content is not republished."
    - "The NewsAPI runtime key is outside TOML at /etc/pulsedeck/secrets/newsapi_api_key; PulseDeck Admin never returns it in clear text."
    - "From patch_0010-1, documentation is bilingual: English primary files in README.md, PROJECT_DESCRIPTION.md, PROJECT_SCHEMA.md and docs/pi/*.md; French mirrors in *.fr.md and docs/pi/fr/*.md."
  unresolved:
    - "Exact application payload schemas outside Weather and News."
    - "Exact cache policy."
    - "Collector cadences outside Weather and News."
    - "ESP-IDF version."
    - "Exact LVGL 9 version."
    - "ST7701 driver."
    - "Touch driver."
    - "Whether EEZ Studio will be used."
    - "OTA."
    - "Asset/image management."

contracts:
  architecture:
    - "The Pi centralizes collection, remote protocols and normalization; the ESP32 focuses on the interface."
    - "MQTT is the primary bus between Pi and ESP32."
    - "A new application does not recreate its own remote network stack and should be addable without modifying other applications."
    - "Heavy processing stays on the Pi when it is better suited there."
  weather:
    - "V1 provider: OpenWeather One Call API 4.0."
    - "Collector uses current, timeline/1h and timeline/1day; 1min and 15min remain outside patch_0007."
    - "Weather snapshots stay retained on provider errors; weather/availability carries source state."
    - "MQTT units are explicitly normalized to Celsius, hPa, percent, m/s and millimeters as applicable."
  news:
    - "V1 provider: NewsAPI v2."
    - "Provider transport: HTTPS only."
    - "Provider authentication: X-Api-Key header only; the key is never put in the query string."
    - "V1 modes: top-headlines or everything. top-headlines supports q/sources/country/category and forbids combining sources with country/category. everything supports q/searchIn/sources/domains/excludeDomains/from/to/language/sortBy."
    - "Initial V1 values: country=fr, category unrestricted, lang=fr for everything, sort_by=publishedAt, max_articles/pageSize=10, interval=1800 s, timeout=15 s; page remains fixed to 1 for the current snapshot."
    - "news/latest schema 1: feed metadata plus normalized articles; provider content deliberately excluded; publishedAt converted to Unix published_ts."
    - "news/availability and news/latest are retained QoS 1; the last valid snapshot remains available after a provider failure."
  persistence:
    - "The ESP32 locally keeps the last valid data so it remains usable when the Pi or MQTT is unavailable."
    - "Detailed cache policy remains unresolved."
  generated_sources:
    - "REPO_INDEX.json is generated by sync-drive.sh using the same publication filter and stays outside the source baseline."
  runtime:
    - "The ESP32 keeps time, interface, navigation and rendering usable independently of Pi/MQTT availability."
    - "Old data is explicitly marked stale; local states are fresh/stale/offline."
    - "The UI is independent of actual collection frequency."
  security:
    - "API keys, Internet HTTPS/TLS and proprietary protocols are centralized on the Pi."
    - "The MQTT V1 broker stays IPv4-LAN-only and must never be exposed directly to the Internet."
    - "Within the current trusted home-LAN scope, MQTT V1 has no authentication, ACL or TLS."
    - "If network scope changes or MQTT carries sensitive commands, the MQTT security model must be reevaluated."
    - "The OpenWeather key is never versioned, stays confined under /etc/pulsedeck and is never returned in clear text by PulseDeck Admin."
    - "The NewsAPI key is never versioned, never put in provider URLs, stays at /etc/pulsedeck/secrets/newsapi_api_key and is never returned in clear text by PulseDeck Admin."
  compatibility:
    - "Target display hardware: ESP32-4848S040C_I, 480 x 480."
    - "LVGL 9 is the UI target; exact version remains unresolved."
    - "Bring-up must validate ST7701 display, touch, PSRAM, Wi-Fi, RGB timings, 480 x 480 rendering and framebuffer stability."
  validation:
    - "V1 must demonstrate a stable Pi <-> ESP32 link."
    - "V1 must demonstrate MQTT outage recovery, retained messages, local cache and fresh/stale/offline states."
    - "V1 must include one complete application, fluid navigation, a first animation and multi-hour memory stability."
  documentation:
    - "PROJECT_DESCRIPTION.md is the canonical project description."
    - "English documentation is authoritative; French mirrors are mandatory."
    - "Primary English files: README.md, PROJECT_DESCRIPTION.md, PROJECT_SCHEMA.md and docs/pi/*.md."
    - "French mirrors: README.fr.md, PROJECT_DESCRIPTION.fr.md, PROJECT_SCHEMA.fr.md and docs/pi/fr/*.md."
  project_specific:
    - "Do not complicate V1 with MQTT clustering, Kubernetes, a heavy database, many microservices, mandatory cloud services, long-term history or a dynamic ESP32 plugin system without a concrete need."

validation:
  commands:
    - command: "./scripts/pulsedeck.sh --check"
      scope: "complete Raspberry Pi preflight: MQTT foundation then hub runtime"
      mode: "external_or_live"
    - command: "./scripts/deploy_hub.sh --check"
      scope: "PulseDeck hub deployment/runtime preflight"
      mode: "external_or_live"
  forbidden_automatic:
    - "dependency installation or upgrade outside an explicitly invoked PulseDeck deployment script"
    - "global Drive -> local repository synchronization"
    - "git commit/push/reset/clean/restore/stash without explicit instruction"
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
```

## Status

The application contracts above come only from `PROJECT_DESCRIPTION.md` and explicitly confirmed project parameters. Entries marked `unresolved` are not implementation requirements.
