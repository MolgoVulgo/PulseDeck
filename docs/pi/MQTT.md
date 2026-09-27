# MQTT — Contrat V1 Raspberry Pi

## Broker

- Mosquitto natif
- TCP 1883
- LAN IPv4 uniquement
- jamais exposé directement à Internet
- authentification : aucune en V1
- ACL : aucune en V1
- TLS : aucun en V1
- persistence broker : activée

Le choix sans authentification/ACL/TLS est limité au réseau domestique actuel. Un changement de périmètre réseau ou l'ajout de commandes sensibles impose de réévaluer ce modèle.

## Installation

La configuration MQTT peut être installée sans dépôt PulseDeck au moyen du script autonome :

```text
scripts/bootstrap_pi.sh
```

Le script embarque le fragment de configuration Mosquitto ; il ne dépend d'aucun template externe au runtime.

## Bind réseau

Le broker écoute explicitement sur l'adresse IPv4 LAN du Pi, détectée via l'interface portant la route par défaut. L'adresse observée au lancement est `192.168.0.250/24` sur `enu1u1u1`, mais elle n'est pas codée en dur.

## Namespace

```text
pulsedeck/v1/...
```

Topics initiaux :

```text
pulsedeck/v1/system/availability

pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily

pulsedeck/v1/news/availability
pulsedeck/v1/news/latest

pulsedeck/v1/pc/gamer/availability
pulsedeck/v1/pc/gamer/dashboard

pulsedeck/v1/server/mini/availability
pulsedeck/v1/server/mini/dashboard

pulsedeck/v1/printer/availability
pulsedeck/v1/printer/status
pulsedeck/v1/printer/job
pulsedeck/v1/printer/thumbnail
```

## QoS

- QoS 1 : états, disponibilités et snapshots applicatifs ;
- QoS 0 : flux rapides/éphémères éventuels ;
- QoS 2 : non utilisé.

## Retained et reprise

Les états courants et les topics `availability` sont retained afin qu'un ESP32 qui démarre ou se reconnecte récupère immédiatement le dernier état valide. Les flux rapides éventuels ne sont pas retained.

Le hub utilisera un Last Will retained sur `pulsedeck/v1/system/availability`. Les disponibilités des sources seront publiées séparément.

## Payloads

Les payloads restent versionnés, normalisés, simples à parser, adaptés à l'affichage et timestampés. Leur schéma JSON exact reste volontairement non défini à ce stade.
