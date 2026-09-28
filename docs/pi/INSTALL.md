# Raspberry Pi Installation

> English is authoritative. French translation: [`fr/INSTALL.md`](fr/INSTALL.md).

## Principle

The Raspberry Pi is a deployment target. The PulseDeck Git repository does not need to be cloned on it.

Deployment scripts follow three rules:

1. anything that can be detected or configured deterministically is automated;
2. service-specific functional configuration is handled by PulseDeck Admin, not by installer prompts;
3. every script is rerunnable and provides a read-only `--check` mode.

## Recommended entry point

The persistent **`pulsedeck` master launcher** is the normal entry point after the first installation. `setup_pi.sh` remains the worker/orchestrator used by that launcher. A fresh target needs one bootstrap download of `setup_pi.sh`; later updates do not.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/setup_pi.sh \
  -o setup_pi.sh
chmod +x setup_pi.sh

./setup_pi.sh --check
sudo ./setup_pi.sh
```

The standalone script downloads `bootstrap_pi.sh` and `deploy_hub.sh` from GitHub when they are not present locally. A repository checkout is optional.

During an apply deployment, `deploy_hub.sh` installs `/usr/local/sbin/pulsedeck`. On later runs:

```bash
pulsedeck --check
sudo pulsedeck
sudo pulsedeck --hub-only
```

The master launcher checks GitHub for `pulsedeck.sh`, `setup_pi.sh`, `bootstrap_pi.sh` and `deploy_hub.sh`, validates shell syntax, updates only changed cached copies under `/var/lib/pulsedeck/installer/scripts/`, and executes the refreshed setup worker. `--offline` explicitly skips the GitHub refresh and uses the cache.

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
- installs/updates the persistent `/usr/local/sbin/pulsedeck` master launcher;
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
/usr/local/sbin/pulsedeck
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
sudo pulsedeck --hub-only
sudo pulsedeck --bootstrap-only
pulsedeck --check --verbose
```

A normal hub update preserves runtime collector settings and secrets.
