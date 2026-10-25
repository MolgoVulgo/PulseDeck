# PulseDeck ESP32 — MQTT connection and Monitoring (`patch_0007`)

## Confirmed baseline and broker contract

- `docs/pi/MQTT.md` is authoritative for the running Pi MQTT namespace (`pulsedeck/v1`); historical `hub/v1/...` proposals from `PROJECT_DESCRIPTION.md` are **not** the active topic contract.
- LAN Mosquitto is configured for anonymous MQTT 3.1.1 on TCP port 1883 (the listener binds to Pi LAN IPv4). No TLS/authentication in the current trusted LAN architecture.
- The initial broker hostname is `192.168.0.250`, with `PD_MQTT_BROKER_DEFAULT` and private `s_broker_host[64]` reserved for a future configuration system. `PD_MQTT_PORT_DEFAULT=1883`; the port also has a private pre-start variable. No NVS, setter, AP form or runtime mutation in this patch.
- ESP-IDF 5.5 already embeds its MQTT client as IDF component `mqtt`; this patch adds `mqtt` to `PRIV_REQUIRES` and requires no new component download.

## Engine behavior

- `pd_mqtt_start()` starts an asynchronous worker that waits for `PD_WIFI_STA_ONLINE` before initializing/starting ESP-MQTT.
- The client uses MQTT 3.1.1, plaintext TCP in the trusted LAN, a default unique (MAC-derived) client ID, default keepalive and ESP-MQTT's automatic broker reconnect.
- When Wi-Fi leaves STA_ONLINE, worker stops the MQTT client outside the MQTT callback, marks `WAIT_WIFI`, and restarts it after Wi-Fi returns. No LVGL call from worker or MQTT event handler.
- Public `pd_mqtt_status_get()` exposes phase (`WAIT_WIFI`, `CONNECTING`, `CONNECTED`, `DISCONNECTED`, `ERROR`), broker, port, last error, ever-connected and successful connect count. A callback may report an error while the ESP-MQTT engine is reconnecting. Status is a snapshot, not a guarantee of broker reachability.
- **No MQTT subscribe, unsubscribe, publish, enqueue, data-handler, MQTT Last Will, or topic discovery is implemented.** No new application availability topic is invented. All broker authentication, subscriptions, command topic handling and message/caching implementation are deferred. A broker connection alone cannot enumerate topic availability.

## Monitoring screen

- Creates runtime-only LVGL widgets in `esp/main/main.c` after SquareLine `ui_init()`; SquareLine-generated files and navigation gesture callbacks are untouched.
- Displays broker address, connection status and **13 documented potential subscriptions**, taken from `docs/pi/MQTT.md`, with `pulsedeck/v1/` namespace and logical `<id>` placeholders for machines and printers.
- Clearly labels the topic list `0 abonnes`: a *catalogue*, **not** subscriptions discovered by querying the broker. Does not fetch retained messages.
- Monitoring UI is updated on the existing LVGL task through a timer. Vertical topic scrolling and gesture bubbling aim to preserve the horizontal navigation. Validate physically, especially a horizontal swipe starting over the scrollable list.

## Local verification requested (Codex)

- Confirm `REPO_INDEX.json` baseline, file hashes, all untouched SquareLine exports and no secret values in archive.
- `python scripts/sync_deploy_payload.py --check`, `git diff --check`, `idf.py build`; do not auto-install/update dependencies.
- Flash with authorization, monitor: successful STA IP -> MQTT CONNECTED to `192.168.0.250:1883` if broker available. On broker rejection/offline show an error/disconnected state without blocking the UI. On Wi-Fi outage expect WAIT_WIFI and recovery. Do not assume remote broker is reachable until proven.
- Observe `Clock <-> Meteo <-> Monitoring <-> ESP32` physical gestures, including swipes across the MQTT list, and list scrolling.
- Confirm no MQTT SUBSCRIBE and no MQTT PUBLISH packets were emitted (prefer a broker-side observation or packet trace if possible; source static check only proves application has no subscribe/publish call).
- Store relevant redacted evidence under `diagnostics/patch_0007/`: `report.md`, hashes, brief monitor excerpt and MQTT/UI check summary. Do not upload private IPs other than the explicitly provided broker target, MACs, passwords, credentials or message payloads.

## Limitations

- No ESP-IDF build or physical MQTT/wifi/touch tests were executable during ChatGPT Web construction. Runtime behavior is to be established by Codex.
- V1 broker is anonymous and unencrypted; reuse only on trusted isolated LAN. An IP or listener mismatch, firewall, or Mosquitto stopped will leave the client reconnecting.
- Topic catalogue is a documented list, not confirmation of currently published topics; dynamic machine/printer IDs are unknown without Pi Admin configuration.
