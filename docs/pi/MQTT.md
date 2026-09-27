# MQTT — Contrat V1 Raspberry Pi

## Broker

- Mosquitto natif ;
- TCP `1883` ;
- LAN IPv4 uniquement ;
- jamais exposé directement à Internet ;
- authentification : aucune en V1 ;
- ACL : aucune en V1 ;
- TLS : aucun en V1 ;
- persistence broker : activée.

Le choix sans authentification/ACL/TLS est limité au réseau domestique actuel. Un changement de périmètre réseau ou l'ajout de commandes sensibles impose de réévaluer ce modèle.

## Bind réseau

Le broker écoute explicitement sur l'adresse IPv4 de l'interface portant la route par défaut. Cette adresse est détectée au moment de l'installation et n'est pas codée en dur dans le dépôt.

Le template versionné est :

```text
config/mosquitto/pulsedeck.conf.in
```

Configuration rendue :

```conf
listener 1883 <IPv4_LAN>
listener_allow_anonymous true

persistence true
persistence_location /var/lib/mosquitto/
autosave_interval 1800
```

Le setup vérifie qu'aucun autre `listener 1883` ou ancien `port 1883` actif n'entre en conflit avant de créer la configuration PulseDeck.

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

Le broker n'interdit pas techniquement QoS 2 ; cette règle appartient au contrat applicatif PulseDeck.

## Retained et persistence

Les états courants et les topics `availability` sont retained afin qu'un ESP32 qui démarre ou se reconnecte récupère immédiatement le dernier état valide. Les flux rapides éventuels ne sont pas retained.

La persistence intégrée de Mosquitto est activée. Le setup valide cette propriété en publiant temporairement un message retained QoS 1, en redémarrant le broker puis en vérifiant que le message est restauré. Le topic de test est ensuite effacé.

## Last Will

Le hub utilisera un Last Will retained sur :

```text
pulsedeck/v1/system/availability
```

La validation du Last Will dépend du client MQTT du hub et reste donc à réaliser avec l'implémentation du service `pulsedeck-hub`.

## Payloads

Les payloads restent versionnés, normalisés, simples à parser, adaptés à l'affichage et timestampés. Leur schéma JSON exact reste à définir application par application.
