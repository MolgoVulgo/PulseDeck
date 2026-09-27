# Raspberry Pi Installation

> English is authoritative. French translation: [`fr/INSTALL.md`](fr/INSTALL.md).

## Principle

The Raspberry Pi is a deployment target. The PulseDeck Git repository does not need to be cloned on it.

Deployment scripts follow three rules:

1. anything that can be detected or configured deterministically is automated;
2. service-specific functional configuration is handled by PulseDeck Admin, not by installer prompts;
3. every script is rerunnable and provides a read-only `--check` mode.

## Recommended entry point

`setup_pi.sh` is the normal installer for both a fresh target and an existing installation.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/setup_pi.sh \
  -o setup_pi.sh
chmod +x setup_pi.sh

./setup_pi.sh --check
sudo ./setup_pi.sh
```

The standalone script downloads `bootstrap_pi.sh` and `deploy_hub.sh` from GitHub when they are not present locally. A repository checkout is optional.

Main options:

```text
--check              validate without changing the target
--verbose            print additional diagnostics
--bootstrap-only     install/check MQTT foundation only
--hub-only           install/check pulsedeck-hub only
--non-interactive    never request manual input
--source-dir DIR     use local specialized scripts from DIR
--ref REF            Git branch/tag/commit used for downloads
```

## `bootstrap_pi.sh`

The bootstrap script checks the host, detects the LAN IPv4 address, installs Mosquitto if needed, configures the IPv4-only listener, enables persistence and validates QoS 1 / retained behavior. It never runs `pacman -Sy` or `pacman -Syu`.

## `deploy_hub.sh`

The hub deployer:

- creates/reuses the `pulsedeck` system account;
- installs application sources under `/opt/pulsedeck/hub`;
- creates/reuses `/opt/pulsedeck/venv`;
- installs Python dependencies inside that venv;
- creates or preserves `/etc/pulsedeck/pulsedeck.toml`;
- prepares `/etc/pulsedeck/secrets/`;
- enables PulseDeck Admin on the detected LAN IPv4, port `8080`;
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
/etc/systemd/system/pulsedeck-hub.service
```

## Web Admin after installation

Open:

```text
http://<Pi-LAN-IPv4>:8080
```

On the first Web-enabled deployment, the installer creates the local `admin` credentials and prints the initial password once. Existing credentials are preserved on later upgrades.

## Targeted updates

```bash
sudo ./setup_pi.sh --hub-only
sudo ./setup_pi.sh --bootstrap-only
./setup_pi.sh --check --verbose
```

A normal hub update preserves runtime collector settings and secrets.
