# PulseDeck Agent

**English is authoritative.** French mirror: [`README.fr.md`](README.fr.md).

`agent-001` introduces the source scaffold and V1 functional boundary for the machine-local PulseDeck Agent. It intentionally does not implement a runtime, transport or deployment mechanism yet.

## Role

PulseDeck Agent runs on monitored machines and collects machine-local metrics. It sends those metrics to the Raspberry Pi, which remains the central PulseDeck hub, normalizer and display-oriented MQTT publisher.

The Agent never replaces the Raspberry Pi hub and does not define the ESP32 MQTT contract.

## V1 modules

```text
mandatory  CPU + MEMORY + NETWORK
optional   GPU
```

Initial profiles:

```text
mini-server  = CPU + MEMORY + NETWORK
PC gamer     = CPU + MEMORY + NETWORK + GPU
```

## Locked V1 metrics

CPU:
- usage;
- temperature;
- power when available.

MEMORY:
- used bytes;
- total bytes;
- utilization percentage.

NETWORK:
- configured interface;
- RX throughput;
- TX throughput;
- RX byte counter;
- TX byte counter.

GPU when enabled:
- usage;
- temperature;
- power;
- core clock;
- memory clock;
- VRAM used and total;
- fan telemetry when available.

Unavailable optional telemetry stays unavailable; it must not be synthesized as zero.

## Source scaffold

```text
agent/
├── README.md
├── README.fr.md
└── src/
    └── pulsedeck_agent/
        ├── __init__.py
        ├── collectors/
        │   ├── __init__.py
        │   ├── cpu.py
        │   ├── memory.py
        │   ├── network.py
        │   └── gpu.py
        └── models/
            └── __init__.py
```

## Intentionally unresolved in agent-001

- exact Agent-to-Pi transport and protocol;
- exact Agent payload schema;
- runtime configuration format;
- service/deployment method;
- sampling and publication cadence;
- history ownership and retention.

These decisions must be documented before implementation and must preserve the Raspberry Pi as the central normalization and MQTT publication point.
