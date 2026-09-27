# Exploitation Raspberry Pi

> L’anglais fait référence : [`../OPERATIONS.md`](../OPERATIONS.md).

## Contrôles globaux

```bash
./setup_pi.sh --check
./setup_pi.sh --check --verbose
```

## Services

```bash
systemctl status mosquitto --no-pager
systemctl status pulsedeck-hub --no-pager
```

Logs :

```bash
sudo journalctl -u mosquitto -n 100 --no-pager
sudo journalctl -u pulsedeck-hub -n 100 --no-pager -o cat
sudo journalctl -u pulsedeck-hub -f
```

## Contrôles MQTT

Availability du hub :

```bash
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 \
  -t pulsedeck/v1/system/availability -C 1
```

Weather :

```bash
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/availability -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/current -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/hourly -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/daily -C 1
```

News :

```bash
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/news/availability -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/news/latest -C 1
```

## Endpoint de santé Admin

L’endpoint non authentifié reste volontairement minimal :

```bash
curl -fsS http://<PI_IPV4>:8080/api/health
```

La configuration des collectors et le statut détaillé nécessitent une session Admin authentifiée.

## Configuration runtime

```text
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/openweather_api_key
/etc/pulsedeck/secrets/gnews_api_key
```

Pour les changements normaux, utiliser PulseDeck Admin plutôt qu’une édition manuelle.

## Comportement en erreur

Les derniers snapshots retained valides Weather et News sont conservés si le fournisseur distant échoue. Le topic `*/availability` correspondant porte l’état courant de la source et une raison non sensible. Les clés fournisseur ne sont jamais journalisées.
