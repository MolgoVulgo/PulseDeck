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

## État validé

Le broker est opérationnel sur `bluebox` et écoute uniquement sur `192.168.0.250:1883`. Le test QoS 1 retained et sa restauration après redémarrage ont été exécutés avec succès le 27 septembre 2026.

## Hub applicatif

Déploiement sans dépôt :

```bash
./deploy_hub.sh --check
sudo ./deploy_hub.sh
```

Exploitation :

```bash
systemctl status pulsedeck-hub
journalctl -u pulsedeck-hub
journalctl -u pulsedeck-hub -f
```

Contrôle du retained :

```bash
mosquitto_sub -h 192.168.0.250 -p 1883 -q 1 -t pulsedeck/v1/system/availability -C 1
```

La valeur d'hôte ci-dessus correspond à la cible observée ; utiliser l'IPv4 LAN actuelle du Pi si elle change.
