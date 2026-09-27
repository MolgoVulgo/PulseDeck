# Exploitation Raspberry Pi

Ce document décrit les commandes d'exploitation prévues. Les services ne sont pas encore installés par `patch_0001`.

## Préflight

```bash
./scripts/setup_pi.sh --check
./scripts/setup_pi.sh --check --verbose
```

## Services futurs

```bash
systemctl status mosquitto
systemctl status pulsedeck-hub
```

## Logs futurs

```bash
journalctl -u mosquitto
journalctl -u pulsedeck-hub
journalctl -u pulsedeck-hub -f
```

## Diagnostic MQTT futur

La validation du patch MQTT devra couvrir au minimum :
- écoute sur l'IPv4 LAN prévue et uniquement celle-ci ;
- publish/subscribe local ;
- publish/subscribe depuis le LAN ;
- retained message ;
- restauration après redémarrage du broker ;
- Last Will du hub ;
- absence d'exposition Internet.

Aucun de ces tests live n'est déclaré réussi par `patch_0001`.
