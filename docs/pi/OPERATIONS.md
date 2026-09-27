# Exploitation Raspberry Pi

## Contrôle global

```bash
./setup_pi.sh --check
./setup_pi.sh --check --verbose
```

Le contrôle global exécute les vérifications du socle MQTT puis celles du hub.

## Installation / mise à jour globale

```bash
sudo ./setup_pi.sh
```

Cette commande est le point d'entrée normal pour une cible PulseDeck neuve ou déjà installée.

## Opérations ciblées

Socle MQTT uniquement :

```bash
./bootstrap_pi.sh --check
sudo ./bootstrap_pi.sh
```

Hub uniquement :

```bash
./deploy_hub.sh --check
sudo ./deploy_hub.sh
```

Via l'orchestrateur :

```bash
sudo ./setup_pi.sh --bootstrap-only
sudo ./setup_pi.sh --hub-only
```

## Services

```bash
systemctl status mosquitto --no-pager
systemctl status pulsedeck-hub --no-pager
```

Logs :

```bash
journalctl -u mosquitto
journalctl -u pulsedeck-hub
journalctl -u pulsedeck-hub -f
```

## Contrôles MQTT

Listener :

```bash
ss -lntp | grep ':1883'
```

Availability du hub :

```bash
mosquitto_sub \
  -h 192.168.0.250 \
  -p 1883 \
  -q 1 \
  -t pulsedeck/v1/system/availability \
  -C 1
```

L'adresse ci-dessus correspond à la cible `bluebox` validée. Utiliser l'IPv4 LAN actuelle du Pi si elle change.

## Comportement en erreur

Les warnings n'interrompent pas les contrôles indépendants. Une erreur sur le bootstrap empêche en revanche le déploiement automatique du hub dans le mode complet, afin de ne pas masquer un socle MQTT incomplet.

Lorsqu'une décision sûre n'est pas possible, le script doit soit demander l'information nécessaire en mode interactif, soit échouer clairement en mode `--non-interactive`.

## Weather

Availability du fournisseur :

```bash
mosquitto_sub \
  -h 192.168.0.250 \
  -p 1883 \
  -q 1 \
  -t pulsedeck/v1/weather/availability \
  -C 1
```

Temps actuel retained :

```bash
mosquitto_sub \
  -h 192.168.0.250 \
  -p 1883 \
  -q 1 \
  -t pulsedeck/v1/weather/current \
  -C 1
```

Prévisions :

```bash
mosquitto_sub -h 192.168.0.250 -p 1883 -q 1 -t pulsedeck/v1/weather/hourly -C 1
mosquitto_sub -h 192.168.0.250 -p 1883 -q 1 -t pulsedeck/v1/weather/daily -C 1
```

Configuration :

```text
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/openweather_api_key
```

Logs du collector :

```bash
journalctl -u pulsedeck-hub -f
```
