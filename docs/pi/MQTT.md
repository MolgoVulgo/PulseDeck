# MQTT Contract

> English is authoritative. French translation: [`fr/MQTT.md`](fr/MQTT.md).

## Broker

PulseDeck V1 uses native Mosquitto as a LAN-only data bus.

- TCP port `1883`;
- listener bound to the detected LAN IPv4 address;
- never exposed directly to the Internet;
- no MQTT authentication, ACL or TLS in the current trusted home-LAN scope;
- persistence enabled;
- retained state/snapshot messages;
- MQTT 3.1.1 clients initially.

If the network trust boundary changes or MQTT carries sensitive commands, this security model must be revisited.

## Namespace

```text
pulsedeck/v1/...
```

## QoS policy

- QoS 1: state and snapshots;
- QoS 0: optional fast/realtime streams;
- QoS 2: unused in V1.

## Topics

```text
pulsedeck/v1/system/availability

pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily

pulsedeck/v1/news/availability
pulsedeck/v1/news/latest

pulsedeck/v1/pc/gamer/availability
pulsedeck/v1/pc/gamer/dashboard

pulsedeck/v1/server/mini/availability
pulsedeck/v1/server/mini/dashboard

pulsedeck/v1/printer/availability
pulsedeck/v1/printer/status
pulsedeck/v1/printer/job
pulsedeck/v1/printer/thumbnail
```

## Availability

`system/availability` is retained and managed by the hub with an MQTT Last Will. Collector availability topics describe the remote source/connectivity state, not the ESP32 display freshness.

The ESP32 derives `fresh`, `stale` and `offline` locally from payload timestamps and connection state.

## Snapshot behavior

Weather and News snapshot topics are retained with QoS 1. A provider failure does not erase the last good retained payload; only the source availability changes to `offline` until recovery.
