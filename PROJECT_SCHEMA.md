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
    - "agent/src/pulsedeck_agent/__main__.py"
    - "agent/scripts/install.sh"
  modules:
    - "Raspberry Pi: central collection orchestration, normalization, aggregation, cache and data publication"
    - "PulseDeck Agent: machine-local CPU, memory and network collection with optional GPU collection; sends machine metrics to the Raspberry Pi"
    - "MQTT: primary data bus between backend and ESP32"
    - "ESP32-S3: Wi-Fi, MQTT, local NTP, local cache, freshness state and LVGL UI"
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
    - "The Admin framework now includes implemented News, multi-machine Agent monitoring and multi-printer configuration; monitored machines are no longer fixed to a gaming-PC slot."
    - "News V1 supports selectable NewsAPI v2 and GNews v4 providers over HTTPS only, with authentication sent only in X-Api-Key."
    - "NewsAPI supports top-headlines/everything; GNews supports top-headlines/search. Provider-specific fields are exposed dynamically in PulseDeck Admin and both providers normalize to the same News MQTT schema."
    - "News V1 defaults: top-headlines, country=fr, no category restriction, max_articles/pageSize=10, interval=1800 s; configurable in PulseDeck Admin."
    - "News V1 publishes retained QoS 1 schema 1 on news/availability and news/latest; provider content is not republished."
    - "News provider secrets are separate: /etc/pulsedeck/secrets/newsapi_api_key and /etc/pulsedeck/secrets/gnews_api_key; PulseDeck Admin never returns either in clear text."
    - "From patch_0010-1, documentation is bilingual: English primary files in README.md, PROJECT_DESCRIPTION.md, PROJECT_SCHEMA.md and docs/pi/*.md; French mirrors in *.fr.md and docs/pi/fr/*.md."
    - "PulseDeck Agent V1 uses one common codebase for every monitored PC/server; mini-server and PC gamer are initial deployment profiles, not fixed hub slots."
    - "PulseDeck Agent V1 mandatory modules: CPU, MEMORY and NETWORK; GPU is optional and configuration-driven."
    - "Initial Agent profiles: mini-server = CPU + MEMORY + NETWORK; PC gamer = CPU + MEMORY + NETWORK + GPU."
    - "Agent V1 CPU metrics: usage, temperature and power when available."
    - "Agent V1 MEMORY metrics: used bytes, total bytes and utilization percentage."
    - "Agent V1 NETWORK metrics: configured interface, RX/TX throughput and RX/TX byte counters."
    - "Agent V1 GPU metrics when enabled: usage, temperature, power, core/memory clocks, VRAM used/total and fan telemetry when available."
    - "From agent-002, Agent runtime configuration is YAML at /etc/pulsedeck-agent/agent.yml."
    - "From agent-002, systemd supervises pulsedeck-agent.service; local diagnostic state is written under /var/lib/pulsedeck-agent/."
    - "From agent-002-1, installation methods are mutually exclusive: Arch/pacman systems use makepkg only; the standalone installer is reserved for non-Arch Linux and refuses Arch/pacman hosts; both use the same agent/ source tree."
    - "From agent-004, the Arch installer builds from a fresh temporary checkout of the selected remote channel, pins the build to the resolved Git commit, and must not depend on local working-tree contents."
    - "From agent-004-1, the Arch installer authenticates sudo once, builds the package without makepkg-driven installation, then installs it explicitly with non-interactive pacman; subsequent privileged steps use the same sudo authorization without additional prompts."
    - "From agent-002, the normal user-facing update command is pulsedeck-agent update."
    - "From patch_0021, Agent-to-Pi transport V1 is read-only HTTP on the trusted LAN: GET /v1/snapshot, default TCP port 8765, configurable Agent bind address/port and configurable Pi target host/port."
    - "Patch_0021 defines Agent wire schema 1 as an explicit envelope with schema=1, protocol=pulsedeck-agent-http, response timestamp and a snapshot object; the Pi validates age/health before normalization."
    - "Patch_0021 defined the first Agent-to-Pi HTTP machine path; patch_0022 generalizes it to a configurable fleet under [collectors.machines] and repeated [[collectors.machines.devices]] entries."
    - "Patch_0022 defines dynamic retained QoS 1 machine schema 1 on pulsedeck/v1/machine/<id>/availability and pulsedeck/v1/machine/<id>/dashboard."
    - "Each machine has a stable logical id plus user-configured name, host/IP, port and enabled state; no monitored-machine IP is hardcoded in the hub. 192.168.0.1 remains documentation/example input only."
    - "From patch_0023, PulseDeck Admin discovers a new machine from only its Agent host/IP (plus optional non-default port), reads Agent identity/capabilities from /v1/snapshot, then pre-fills editable id/name/type/host/port fields before save."
    - "PulseDeck Admin can add, edit, test, enable/disable and remove monitored machines; removing a machine clears its retained machine topics."
  unresolved:
    - "Exact application payload schemas outside Weather, News and Machines."
    - "Exact cache policy."
    - "Cadences for future/unimplemented collectors that do not yet have their own contract."
    - "ESP-IDF version."
    - "Exact LVGL 9 version."
    - "ST7701 driver."
    - "Touch driver."
    - "Whether EEZ Studio will be used."
    - "OTA."
    - "Asset/image management."

contracts:
  architecture:
    - "The Pi remains the central collection orchestrator, normalizer and display-oriented MQTT publisher; machine-local Agent instances do not replace the Pi hub."
    - "PulseDeck Agent collects only machine-local metrics; the Pi polls the Agent over the V1 read-only HTTP transport and remains responsible for normalization and display-oriented MQTT publication."
    - "The Pi centralizes collection, remote protocols and normalization; the ESP32 focuses on the interface."
    - "MQTT is the primary bus between Pi and ESP32."
    - "A new application does not recreate its own remote network stack and should be addable without modifying other applications."
    - "Heavy processing stays on the Pi when it is better suited there."
  agent:
    - "One common PulseDeck Agent codebase serves all monitored machines in V1."
    - "Mandatory V1 modules: CPU, MEMORY, NETWORK."
    - "Optional V1 module: GPU, enabled by configuration."
    - "Mini-server profile: CPU + MEMORY + NETWORK."
    - "PC gamer profile: CPU + MEMORY + NETWORK + GPU."
    - "NETWORK follows the YAML-selected interface; interface=auto resolves the default-route interface when possible, and the collector reports RX/TX throughput plus RX/TX byte counters."
    - "Unavailable optional telemetry such as CPU/GPU power or GPU fan data must remain unavailable rather than being synthesized as zero."
    - "Agent runtime configuration format is YAML at /etc/pulsedeck-agent/agent.yml; CPU, MEMORY and NETWORK are mandatory and GPU alone has an enabled switch."
    - "Agent service supervision uses systemd via pulsedeck-agent.service."
    - "Arch/pacman installation uses agent/packaging/arch/install.sh as the user entry point and agent/packaging/arch/PKGBUILD with makepkg; makepkg runs as a regular user, the build source is a clean remote checkout, the exact source commit is pinned before packaging, and package installation is performed explicitly through non-interactive pacman after one sudo authentication."
    - "agent/scripts/install.sh is the standalone installer for non-Arch Linux only and must refuse Arch/pacman hosts before making system changes."
    - "Standalone installation uses agent/scripts/install.sh and an isolated runtime under /opt/pulsedeck-agent."
    - "Both installation paths expose the common command pulsedeck-agent and normal updates use pulsedeck-agent update."
    - "agent-002 local snapshot.json is diagnostic/internal Agent state and does not define the Agent-to-Pi wire payload."
    - "Agent HTTP transport is disabled unless enabled in /etc/pulsedeck-agent/agent.yml; listen address and port are configurable, with default port 8765 and fixed snapshot endpoint /v1/snapshot."
    - "The V1 Agent HTTP endpoint is read-only and unauthenticated only within the current trusted LAN scope; it must not be exposed directly to the Internet."
  machines:
    - "Hub configuration uses [collectors.machines] plus repeated [[collectors.machines.devices]] entries with stable id, display name, user-editable type (server/pc/laptop/other), host/IP, port and enabled state."
    - "The Pi Machines collector accepts one or more configurable devices, polls each enabled Agent independently, rejects stale or unhealthy snapshots, and uses configurable poll_interval/request_timeout/offline_after_failures/max_snapshot_age settings."
    - "Machine MQTT schema 1 uses retained QoS 1 on machine/<id>/availability and machine/<id>/dashboard, where <id> is the configured logical machine id."
    - "machine/<id>/dashboard schema 1 contains schema, ts, source, machine{id,name,host}, agent{id,name}, capabilities and data. data always contains cpu{usage_pct,temperature_c,power_w}, memory{used_b,total_b,usage_pct} and network{interface,rx_bps,tx_bps,rx_bytes,tx_bytes}; gpu{usage_pct,temperature_c,power_w,core_clock_mhz,memory_clock_mhz,vram_used_b,vram_total_b,fan_rpm,fan_pct} is included when advertised/present."
    - "Unavailable optional readings remain null; they are never synthesized as zero."
    - "machine/<id>/availability uses source availability schema 1 with source=pulsedeck-agent, state online/offline, ts and optional last_success/reason."
    - "Machine dashboards carry both configured logical-machine identity and Agent-reported identity/capabilities; the logical id is not required to equal the Agent id."
    - "PulseDeck Admin supports discovery-by-host followed by editable id/name/type/host/port fields, plus test/enable-disable/remove operations, and hot reloads the fleet without restarting the hub."
    - "Discovery is advisory metadata only: Agent id/name and capabilities are read from the live snapshot; type is suggested as pc when GPU capability is advertised and server otherwise, and the user may change it before save."
    - "Legacy [collectors.mini_server] from patch_0021 is accepted for in-memory migration; the first Machines Admin save persists the canonical multi-device format and removes the legacy section."
  weather:
    - "V1 provider: OpenWeather One Call API 4.0."
    - "Collector uses current, timeline/1h and timeline/1day; 1min and 15min remain outside patch_0007."
    - "Weather snapshots stay retained on provider errors; weather/availability carries source state."
    - "MQTT units are explicitly normalized to Celsius, hPa, percent, m/s and millimeters as applicable."
  news:
    - "V1 providers: NewsAPI v2 and GNews v4; provider is selectable in Admin."
    - "Provider transport: HTTPS only."
    - "Provider authentication: X-Api-Key header only; the key is never put in the query string."
    - "NewsAPI modes: top-headlines/everything. GNews modes: top-headlines/search; GNews search requires q (<=200 chars), supports in/nullable/from/to/lang/country/sortby, and GNews top-headlines exposes nine categories."
    - "Default provider remains NewsAPI for migration compatibility; max_articles=10, interval=1800 s, timeout=15 s and provider pagination page=1 for the current snapshot."
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
    - "NewsAPI/GNews keys are never versioned or put in provider URLs; they stay in separate files under /etc/pulsedeck/secrets and are never returned in clear text by PulseDeck Admin."
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
    - "Primary English files: README.md, PROJECT_DESCRIPTION.md, PROJECT_SCHEMA.md, agent/README.md and docs/pi/*.md."
    - "French mirrors: README.fr.md, PROJECT_DESCRIPTION.fr.md, PROJECT_SCHEMA.fr.md, agent/README.fr.md, agent/docs/fr/*.md and docs/pi/fr/*.md."
  project_specific:
    - "Do not complicate V1 with MQTT clustering, Kubernetes, a heavy database, many microservices, mandatory cloud services, long-term history or a dynamic ESP32 plugin system without a concrete need."

validation:
  commands:
    - command: "PYTHONPATH=agent/src python -m unittest discover -s agent/tests -v"
      scope: "PulseDeck Agent unit tests without installation or network transport"
      mode: "targeted"
    - command: "PYTHONPATH=agent/src python -m pulsedeck_agent --config agent/config/pulsedeck-agent.example.yml config validate"
      scope: "PulseDeck Agent example YAML validation"
      mode: "targeted"
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
    - "/etc/pulsedeck/secrets/gnews_api_key"
```

## Status

The application contracts above come only from `PROJECT_DESCRIPTION.md` and explicitly confirmed project parameters. Entries marked `unresolved` are not implementation requirements.
