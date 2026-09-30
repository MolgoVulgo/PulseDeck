# PulseDeck Agent installation

**English is authoritative.** French mirror: [`fr/INSTALL.md`](fr/INSTALL.md).

## Common result

Both supported installation paths provide:

- `pulsedeck-agent` command;
- `/etc/pulsedeck-agent/agent.yml` YAML configuration;
- `pulsedeck-agent.service` systemd unit;
- automatic start at boot;
- installed source channel metadata (`main` or `dev`);
- `pulsedeck-agent doctor` for complete installation verification;
- `pulsedeck-agent update` for normal updates on the same channel.

The default configuration enables CPU, MEMORY and NETWORK and leaves GPU disabled. The methods are mutually exclusive: Arch Linux/pacman-based systems use the package path, while the standalone installer is reserved for non-Arch Linux systems.

## Method 1 — Arch Linux / makepkg

Run the installer as a normal user, never as root. It asks for `sudo` once for package/system operations. Missing Arch build prerequisites (`base-devel` and Git) are installed automatically through pacman when needed.

### Stable channel (`main`) — one command

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/agent/packaging/arch/install.sh \
  | bash
```

### Development channel (`dev`) — one command

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/dev/agent/packaging/arch/install.sh \
  | bash -s -- dev
```

From an existing PulseDeck checkout, the equivalent command is simply:

```bash
./agent/packaging/arch/install.sh
```

When that local script is on `main` or `dev`, it uses the current branch automatically. You may also select the channel explicitly:

```bash
./agent/packaging/arch/install.sh main
./agent/packaging/arch/install.sh dev
```

The local checkout is used only to select the channel. The package is always built from a new temporary clone of the remote repository, so a dirty checkout, an old build directory, or a locally edited `PKGBUILD` cannot contaminate the installation. The installer resolves the remote channel to an exact commit and passes that commit to `PKGBUILD`; the built package and its recorded `source-revision` therefore refer to the same source revision.

The installer then prepares the fixed `pulsedeck-agent` service account/state directory, reloads systemd, enables/restarts `pulsedeck-agent.service`, and runs `pulsedeck-agent doctor`. If the final health check fails, the installer prints the service status, recent journal entries, and installed identity automatically before returning a failure code.

The package stores:

```text
/usr/share/pulsedeck-agent/install-method
/usr/share/pulsedeck-agent/source-ref
/usr/share/pulsedeck-agent/source-revision
```

Check the installed identity at any time:

```bash
pulsedeck-agent version
```

Normal update is one command:

```bash
pulsedeck-agent update
```

An Agent installed from `dev` stays on `dev`; an Agent installed from `main` stays on `main`. Updates reuse the same clean remote-build path and finish with `pulsedeck-agent doctor`.

## Method 2 — standalone installer (non-Arch Linux only)

This method is for Linux systems that are not Arch/pacman-based. On Arch Linux or a pacman-based compatible system, `install.sh` exits without modifying the machine and points to the package procedure.

Stable remote bootstrap:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/agent/scripts/install.sh \
  | sudo bash
```

Development remote bootstrap:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/dev/agent/scripts/install.sh \
  | sudo bash -s -- --ref dev
```

From an existing PulseDeck source checkout:

```bash
sudo ./agent/scripts/install.sh --source "$PWD"
```

If the checkout branch is `main` or `dev`, the standalone installer automatically records that channel unless `--ref` is given explicitly.

The standalone method installs an isolated Python environment under `/opt/pulsedeck-agent`, exposes `/usr/local/bin/pulsedeck-agent`, creates the fixed `pulsedeck-agent` system account through `systemd-sysusers`, installs the systemd unit, preserves an existing YAML configuration and starts the service.

Normal update:

```bash
pulsedeck-agent update
```

The updater reuses the channel recorded during installation.

## Service account and local state

The service runs as the fixed system user `pulsedeck-agent`. The state directory is `/var/lib/pulsedeck-agent` with mode `0755`; runtime files such as `snapshot.json` are written as `0644`. Normal users can therefore run `pulsedeck-agent doctor` without `sudo`, while only the service account writes Agent state.

Upgrading from the earlier `DynamicUser=yes` draft automatically discards the old private diagnostic state under `/var/lib/private/pulsedeck-agent` and recreates a fresh state directory. The snapshot is diagnostic state only and is not a history store or an Agent -> Pi payload contract.

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

Validate and restart after a configuration change:

```bash
pulsedeck-agent config validate
sudo systemctl restart pulsedeck-agent.service
pulsedeck-agent doctor
```

## Verify that the installation is healthy

Run:

```bash
pulsedeck-agent doctor
```

A healthy mini-server installation should look similar to:

```text
PulseDeck Agent doctor

Version       : 0.1.0
Install       : arch-package
Channel       : dev
Revision      : 0123456789abcdef...
Agent ID      : mini-server

Configuration : OK
CPU           : OK
Memory        : OK
Network       : OK (enp1s0)
GPU           : disabled
Service       : active
Autostart     : enabled
State dir     : OK (pulsedeck-agent:pulsedeck-agent 0755)
Snapshot      : OK (age 0.4s)

Result: OK
```

The command returns exit code `0` only when all required checks pass:

```bash
pulsedeck-agent doctor
echo $?
```

If `Result: FAILED` is reported, the failing line identifies the first area to investigate. `pulsedeck-agent status`, `systemctl status pulsedeck-agent.service` and `journalctl -u pulsedeck-agent.service` remain available for narrower troubleshooting.

## Standalone uninstall

```bash
sudo /usr/local/libexec/pulsedeck-agent/uninstall.sh
```

Configuration and state are preserved by default. To remove them too:

```bash
sudo /usr/local/libexec/pulsedeck-agent/uninstall.sh --purge
```

Arch installations should be removed with pacman instead of the standalone uninstaller.
