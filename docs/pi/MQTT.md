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

## Validation live du broker

Validation effectuée sur `bluebox` le 27 septembre 2026 :

```text
Mosquitto        2.1.2-2
IPv4 LAN         192.168.0.250
Interface        enu1u1u1
Listener         192.168.0.250:1883 uniquement
IPv6 globale     absente
Auth / ACL / TLS aucun
QoS 1 retained   validé
Persistence      retained restauré après restart
systemd          service actif et activé au boot
```

Cette validation couvre le broker local. Un test depuis une autre machine du LAN reste une validation séparée du chemin réseau client -> broker.

## Availability du hub — schéma 1

`patch_0003` implémente le premier payload applicatif concret sur :

```text
pulsedeck/v1/system/availability
```

Payload online retained/QoS 1 :

```json
{"schema":1,"state":"online","ts":1790500000,"ts_kind":"event","session_started":1790500000}
```

À l'arrêt propre, le hub publie `state=offline` avec `reason=graceful_shutdown`. Le Last Will utilise également `state=offline`, `reason=connection_lost` et `ts_kind=will_created`. Un Last Will est préparé avant la perte de connexion et ne peut donc pas porter l'heure exacte de la future coupure ; `ts_kind` rend cette limite explicite.

Le client hub utilise MQTT 3.1.1, QoS 1 retained pour l'availability et une reconnexion automatique avec délai exponentiel borné.
