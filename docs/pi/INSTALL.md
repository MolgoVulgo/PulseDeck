# Raspberry Pi Installation

> English is authoritative. French translation: [`fr/INSTALL.md`](fr/INSTALL.md).

## Principle

The Raspberry Pi is a deployment target. The PulseDeck Git repository does not need to be cloned on it.

Deployment scripts follow three rules:

1. anything that can be detected or configured deterministically is automated;
2. service-specific functional configuration is handled by PulseDeck Admin, not by installer prompts;
3. every script is rerunnable and provides a read-only `--check` mode.

## First installation

The only user-facing bootstrap command on a fresh Raspberry Pi is:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/install.sh \
  | sudo bash
```

`install.sh` is intentionally small. It:

1. downloads `scripts/pulsedeck.sh` from the selected Git ref;
2. validates its Bash syntax before installation;
3. installs it as `/usr/local/sbin/pulsedeck`;
4. seeds `/var/lib/pulsedeck/installer/scripts/pulsedeck.sh`;
5. immediately runs the installed master launcher.

The master launcher then refreshes the worker scripts and performs the normal complete installation. The Git repository does not need to be cloned on the Pi.

For a dry run during bootstrap:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/install.sh \
  | sudo bash -s -- --check
```

To install only the persistent launcher without starting deployment:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/install.sh \
  | sudo bash -s -- --install-only
```

## Persistent master launcher

After the first bootstrap, the normal entry point is always:

```bash
sudo pulsedeck
```

Useful variants:

```bash
pulsedeck --check
sudo pulsedeck --hub-only
sudo pulsedeck --bootstrap-only
sudo pulsedeck --offline --hub-only
```

The master launcher checks GitHub for `pulsedeck.sh`, `setup_pi.sh`, `bootstrap_pi.sh` and `deploy_hub.sh`, validates their shell syntax, updates only changed cached copies under `/var/lib/pulsedeck/installer/scripts/`, and executes the refreshed `setup_pi.sh` worker. `--offline` explicitly skips GitHub refresh and uses the cached scripts.

`setup_pi.sh` remains the internal complete orchestrator. It is still usable directly for development/diagnostics, but users do not need to download it manually.

Main options:

```text
--check              validate without changing the target
--verbose            print additional diagnostics
--bootstrap-only     install/check MQTT foundation only
--hub-only           install/check pulsedeck-hub only
--non-interactive    never request manual input
--ref REF            Git branch/tag/commit used for downloads
--offline            master only: skip GitHub refresh and use the cache
```

## `bootstrap_pi.sh`

The bootstrap script checks the host, detects the LAN IPv4 address, installs Mosquitto if needed, configures the IPv4-only listener, enables persistence and validates QoS 1 / retained behavior. It never runs `pacman -Sy` or `pacman -Syu`.

## `deploy_hub.sh`

The hub deployer:

- creates/reuses the `pulsedeck` system account;
- installs application sources under `/opt/pulsedeck/hub`;
- creates/reuses `/opt/pulsedeck/venv`;
- installs Python dependencies inside that venv;
- keeps Python build/install output quiet in normal mode and reports only the step status; detailed pip/build output is shown only with `--verbose`;
- creates or preserves `/etc/pulsedeck/pulsedeck.toml`;
- prepares `/etc/pulsedeck/secrets/`;
- enables PulseDeck Admin on the detected LAN IPv4, port `8080`;
- installs/updates the persistent `/usr/local/sbin/pulsedeck` master launcher;
- installs the root-only `/usr/local/libexec/pulsedeck-updater` worker plus `pulsedeck-updater.service` / `pulsedeck-updater.path`;
- enables the updater path watcher without granting root privileges to the hub process;
- installs and restarts `pulsedeck-hub.service`;
- validates runtime availability.

Functional collector configuration is not requested by the deployer. Configure Weather, News and future services through PulseDeck Admin.

Runtime layout:

```text
/opt/pulsedeck/hub
/opt/pulsedeck/venv
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/
/var/lib/pulsedeck
/var/lib/pulsedeck/installer/scripts
/var/lib/pulsedeck-updater/inbox
/var/lib/pulsedeck-updater/status
/usr/local/sbin/pulsedeck
/usr/local/libexec/pulsedeck-updater
/etc/systemd/system/pulsedeck-hub.service
/etc/systemd/system/pulsedeck-updater.service
/etc/systemd/system/pulsedeck-updater.path
```

## Web Admin after installation

Open:

```text
http://<Pi-LAN-IPv4>:8080
```

On the first Web-enabled deployment, the installer creates the local `admin` credentials and prints the initial password once. Existing credentials are preserved on later upgrades.

## Targeted updates

```bash
sudo pulsedeck --hub-only
sudo pulsedeck --bootstrap-only
pulsedeck --check --verbose
```

A normal hub update preserves runtime collector settings and secrets. When the stable/dev checker reports a newer target, PulseDeck Admin can queue installation of the currently active channel. The Web process only writes a constrained request; the separate root updater validates it and invokes the fixed master-launcher update path. Rollback and a versioned release cache are deferred to a later step.
