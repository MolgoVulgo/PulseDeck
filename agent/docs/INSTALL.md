# PulseDeck Agent installation

**English is authoritative.** French mirror: [`fr/INSTALL.md`](fr/INSTALL.md).

## Common result

Both supported installation paths provide:

- `pulsedeck-agent` command;
- `/etc/pulsedeck-agent/agent.yml` YAML configuration;
- `pulsedeck-agent.service` systemd unit;
- automatic start at boot;
- `pulsedeck-agent update` as the normal update command.

The default configuration enables CPU, MEMORY and NETWORK and leaves GPU disabled. The methods are mutually exclusive: Arch Linux/pacman-based systems use the package path, while the standalone installer is reserved for non-Arch Linux systems. `install.sh` refuses Arch/pacman systems.

## Method 1 — Arch Linux / makepkg

Prerequisites: a normal non-root build user, `base-devel`/`makepkg`, Git and sudo configured for pacman operations.

From a PulseDeck source checkout:

```bash
cd agent/packaging/arch
makepkg -si
sudo systemctl enable --now pulsedeck-agent.service
```

`PKGBUILD` retrieves the PulseDeck source repository and packages `agent/`. Do not run `makepkg` as root.

Normal update:

```bash
pulsedeck-agent update
```

For an Arch package installation, the update helper clones the current PulseDeck source and runs `makepkg -si` as the calling non-root user.

## Method 2 — standalone installer (non-Arch Linux only)

This method is for Linux systems that are not Arch/pacman-based. On Arch Linux or a pacman-based compatible system, `install.sh` exits without modifying the machine and points to the `makepkg` procedure.

Remote bootstrap:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/agent/scripts/install.sh \
  | sudo bash
```

From an existing PulseDeck source checkout:

```bash
sudo ./agent/scripts/install.sh --source "$PWD"
```

The standalone method installs an isolated Python environment under `/opt/pulsedeck-agent`, exposes `/usr/local/bin/pulsedeck-agent`, installs the systemd unit, preserves an existing YAML configuration and starts the service.

Normal update:

```bash
pulsedeck-agent update
```

The updater re-runs the installed standalone installer against the current source ref. No repository clone is required on the target.

## First configuration

Edit:

```text
/etc/pulsedeck-agent/agent.yml
```

Mini-server example:

```yaml
agent:
  id: mini-server
  name: Mini Server
collectors:
  cpu: {}
  memory: {}
  network:
    interface: enp1s0
  gpu:
    enabled: false
runtime:
  sample_interval_s: 1.0
```

Gaming-PC example:

```yaml
agent:
  id: gaming-pc
  name: Gaming PC
collectors:
  cpu: {}
  memory: {}
  network:
    interface: auto
  gpu:
    enabled: true
runtime:
  sample_interval_s: 1.0
```

Validate and restart:

```bash
pulsedeck-agent config validate
pulsedeck-agent check
sudo systemctl restart pulsedeck-agent.service
pulsedeck-agent status
```

## Standalone uninstall

```bash
sudo /usr/local/libexec/pulsedeck-agent/uninstall.sh
```

Configuration and state are preserved by default. To remove them too:

```bash
sudo /usr/local/libexec/pulsedeck-agent/uninstall.sh --purge
```

Arch installations should be removed with pacman instead of the standalone uninstaller.

If an older standalone Agent was previously installed on an Arch/pacman host, remove that standalone installation first with `/usr/local/libexec/pulsedeck-agent/uninstall.sh` before installing the package with `makepkg -si`.
