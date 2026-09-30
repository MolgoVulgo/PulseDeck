# PulseDeck Agent

**English is authoritative.** French mirror: [`README.fr.md`](README.fr.md).

PulseDeck Agent is the machine-local metrics component for monitored PCs and servers. It collects local telemetry and is designed to send it to the Raspberry Pi, which remains the central PulseDeck hub, normalizer and display-oriented MQTT publisher.

`agent-002` is the first executable draft. It implements local collection, YAML configuration, a systemd runtime, Arch `makepkg` packaging, a standalone installer and a common update command. Agent -> Pi transport remains intentionally unimplemented until that contract is defined.

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

Metrics:

- CPU: usage, temperature, power when available;
- MEMORY: used bytes, total bytes, utilization percentage;
- NETWORK: selected interface, RX/TX throughput and RX/TX byte counters;
- GPU when enabled: usage, temperature, power, core/memory clocks, VRAM used/total and fan telemetry when available.

Unavailable optional telemetry remains invalid/null; it is never synthesized as zero.

## Configuration

Runtime configuration is YAML:

```text
/etc/pulsedeck-agent/agent.yml
```

Versioned example: [`config/pulsedeck-agent.example.yml`](config/pulsedeck-agent.example.yml).

CPU, MEMORY and NETWORK cannot be disabled in V1. `collectors.network.interface: auto` resolves the default-route interface when possible. GPU is enabled only with `collectors.gpu.enabled: true`.

The first GPU implementation reuses PulseMon's Linux AMD sysfs approach. GPU being optional is a V1 contract; support for additional GPU vendors is not defined by `agent-002`.

## Commands

```text
pulsedeck-agent version
pulsedeck-agent config path
pulsedeck-agent config validate
pulsedeck-agent check
pulsedeck-agent snapshot
pulsedeck-agent status
pulsedeck-agent update
```

The systemd service runs:

```text
pulsedeck-agent run
```

Until Agent -> Pi transport is defined, `run` collects locally and atomically maintains:

```text
/var/lib/pulsedeck-agent/snapshot.json
```

That file and `snapshot` command are diagnostic/internal Agent state, not the future Agent -> Pi wire payload contract.

## Installation

Two mutually exclusive installation paths are defined:

1. Arch Linux / pacman-based systems: package build with `makepkg -si` only;
2. non-Arch Linux systems: standalone installer `agent/scripts/install.sh` only.

`install.sh` explicitly refuses to run on Arch/pacman-based systems so package-managed and standalone files cannot be mixed. Both paths use the same `agent/` sources and install the same command and systemd service. Updates use one user-facing command:

```bash
pulsedeck-agent update
```

See [`docs/INSTALL.md`](docs/INSTALL.md).

## Source layout

```text
agent/
├── pyproject.toml
├── config/
├── docs/
├── packaging/arch/
├── scripts/
├── systemd/
├── tests/
└── src/pulsedeck_agent/
    ├── collectors/
    ├── models/
    ├── cli.py
    ├── config.py
    └── runtime.py
```

## Still unresolved

- exact Agent -> Pi transport and protocol;
- exact Agent -> Pi payload schema;
- history ownership and retention.

The local `sample_interval_s` value is an Agent implementation setting only; it does not define the future Pi collection/publication cadence.
