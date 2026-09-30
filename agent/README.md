# PulseDeck Agent

**English is authoritative.** French mirror: [`README.fr.md`](README.fr.md).

PulseDeck Agent is the machine-local metrics component for monitored PCs and servers. It collects local telemetry and is designed to send it to the Raspberry Pi, which remains the central PulseDeck hub, normalizer and display-oriented MQTT publisher.

`agent-004` keeps the installation channel contract (`main` or `dev`) and makes the Arch install/update path clean-build by default: local checkout changes cannot affect the package, the selected remote revision is pinned, and post-install health validation is automatic. Agent -> Pi transport remains intentionally unimplemented until that contract is defined.

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

The first GPU implementation reuses PulseMon's Linux AMD sysfs approach. GPU being optional is a V1 contract; support for additional GPU vendors is not defined yet.

## Commands

```text
pulsedeck-agent version
pulsedeck-agent config path
pulsedeck-agent config validate
pulsedeck-agent check
pulsedeck-agent snapshot
pulsedeck-agent status
pulsedeck-agent doctor
pulsedeck-agent update
```

`version` reports the installed method, source channel and source revision. `doctor` is the normal post-installation and post-update verification command. It checks installation metadata, YAML configuration, CPU/MEMORY/NETWORK, optional GPU, systemd active/enabled state, state-directory ownership/mode and the local snapshot. Exit code `0` means the complete diagnostic passed.

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

1. Arch Linux / pacman-based systems: package build through `agent/packaging/arch/install.sh` and `makepkg`;
2. non-Arch Linux systems: standalone installer `agent/scripts/install.sh` only.

On Arch, the installer always builds from a fresh temporary checkout of the selected remote channel. The state of an existing local checkout, including uncommitted changes, cannot affect the package being built. From a checkout, the normal command remains:

```bash
./agent/packaging/arch/install.sh
```

It automatically uses the current Git branch when it is `main` or `dev`; otherwise it defaults to `main`. An explicit channel is also accepted:

```bash
./agent/packaging/arch/install.sh main
./agent/packaging/arch/install.sh dev
```

A remote one-command bootstrap is documented in `docs/INSTALL.md`. The installer resolves a concrete Git revision, pins the package build to that revision, installs prerequisites when necessary, restarts the service, and runs `pulsedeck-agent doctor`. The selected channel is stored with the installed Agent. `pulsedeck-agent update` continues on that same channel and uses the same clean-build path.

`install.sh` for standalone installations explicitly refuses Arch/pacman systems so package-managed and standalone files cannot be mixed.

The systemd service runs under the fixed system account `pulsedeck-agent`. Its state directory `/var/lib/pulsedeck-agent` remains writable only by the service while diagnostic files such as `snapshot.json` are readable by normal users so `pulsedeck-agent doctor` does not require root.

Both installation paths run `pulsedeck-agent doctor` automatically after a normal service start. It can always be re-run manually:

```bash
pulsedeck-agent doctor
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
    ├── metadata.py
    └── runtime.py
```

## Still unresolved

- exact Agent -> Pi transport and protocol;
- exact Agent -> Pi payload schema;
- history ownership and retention.

The local `sample_interval_s` value is an Agent implementation setting only; it does not define the future Pi collection/publication cadence.
