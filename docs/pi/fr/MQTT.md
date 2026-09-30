# Contrat MQTT

> L’anglais fait référence : [`../MQTT.md`](../MQTT.md).

## Broker

PulseDeck V1 utilise Mosquitto natif comme bus de données limité au LAN.

- TCP `1883` ;
- listener lié à l’IPv4 LAN détectée ;
- aucune exposition directe à Internet ;
- pas d’authentification MQTT, ACL ou TLS dans le périmètre LAN domestique de confiance actuel ;
- persistence activée ;
- états/snapshots retained ;
- clients MQTT 3.1.1 initialement.

Si la frontière de confiance réseau change ou si MQTT transporte des commandes sensibles, ce modèle de sécurité doit être réévalué.

## Namespace

```text
pulsedeck/v1/...
```

## QoS

- QoS 1 : états et snapshots ;
- QoS 0 : éventuels flux rapides/realtime ;
- QoS 2 : non utilisé en V1.

## Topics

```text
pulsedeck/v1/system/availability

pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily

pulsedeck/v1/news/availability
pulsedeck/v1/news/latest

pulsedeck/v1/machine/<id>/availability
pulsedeck/v1/machine/<id>/dashboard

pulsedeck/v1/printer/<id>/availability
pulsedeck/v1/printer/<id>/status
pulsedeck/v1/printer/<id>/job
pulsedeck/v1/printer/<id>/thumbnail
```

## Availability

`system/availability` est retained et géré par le hub avec un Last Will MQTT. Les topics d’availability des collectors décrivent l’état de la source distante, pas la fraîcheur d’affichage de l’ESP32.

L’ESP32 dérive localement `fresh`, `stale` et `offline` à partir des timestamps et de l’état de connexion.

## Snapshots

Les snapshots Weather, News, dashboards machine et états Printer sont retained en QoS 1. Pour les machines, `<id>` est l’identifiant logique stable configuré dans PulseDeck Admin ; le Pi interroge le PulseDeck Agent correspondant en HTTP puis publie l’état normalisé sous ce préfixe. Une panne source n’efface pas le dernier dashboard/snapshot valide ; l’availability passe `offline` selon le seuil d’échecs propre à la source.
