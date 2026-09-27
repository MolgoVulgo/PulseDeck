# Exploitation Raspberry Pi

## Préflight sans dépôt

Une copie seule de `bootstrap_pi.sh` suffit :

```bash
./bootstrap_pi.sh --check
./bootstrap_pi.sh --check --verbose
```

## Installation MQTT

```bash
sudo ./bootstrap_pi.sh
```

Le même script est relançable : les opérations sont conçues pour être idempotentes lorsqu'il reconnaît les fichiers PulseDeck qu'il gère.

## Depuis un dépôt PulseDeck présent

```bash
sudo ./scripts/setup_pi.sh
```

`setup_pi.sh` délègue au bootstrap autonome.

## Services

```bash
systemctl status mosquitto
journalctl -u mosquitto
```

## Contrôles MQTT

```bash
ss -lntp | grep ':1883'
```

Le listener attendu est l'IPv4 LAN portée par la route par défaut, port `1883`. Le bootstrap teste également QoS 1, retained et restauration du retained après redémarrage du broker.

## Limites

Le bootstrap n'installe pas encore le service applicatif `pulsedeck-hub`. Cette étape aura son propre mécanisme de déploiement et ne devra pas imposer un clone Git de développement sur le Pi.
