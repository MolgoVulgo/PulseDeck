# PulseDeck Agent

**La version anglaise fait référence.** Version anglaise : [`README.md`](README.md).

`agent-001` introduit le squelette source et la frontière fonctionnelle V1 de PulseDeck Agent, composant local aux machines supervisées. Ce patch n’implémente volontairement ni runtime, ni transport, ni mécanisme de déploiement.

## Rôle

PulseDeck Agent s’exécute sur les machines supervisées et collecte leurs métriques locales. Il transmet ces métriques au Raspberry Pi, qui reste le hub PulseDeck central, le normaliseur et le producteur MQTT destiné à l’affichage.

L’Agent ne remplace jamais le hub Raspberry Pi et ne définit pas le contrat MQTT ESP32.

## Modules V1

```text
obligatoires  CPU + MEMORY + NETWORK
optionnel     GPU
```

Profils initiaux :

```text
mini-serveur  = CPU + MEMORY + NETWORK
PC gamer      = CPU + MEMORY + NETWORK + GPU
```

## Métriques V1 verrouillées

CPU :
- utilisation ;
- température ;
- puissance si disponible.

MEMORY :
- octets utilisés ;
- octets totaux ;
- pourcentage d’utilisation.

NETWORK :
- interface configurée ;
- débit RX ;
- débit TX ;
- compteur d’octets RX ;
- compteur d’octets TX.

GPU lorsqu’il est activé :
- utilisation ;
- température ;
- puissance ;
- fréquence core ;
- fréquence mémoire ;
- VRAM utilisée et totale ;
- ventilation si disponible.

Une télémétrie optionnelle indisponible reste indisponible ; elle ne doit pas être synthétisée à zéro.

## Squelette source

```text
agent/
├── README.md
├── README.fr.md
└── src/
    └── pulsedeck_agent/
        ├── __init__.py
        ├── collectors/
        │   ├── __init__.py
        │   ├── cpu.py
        │   ├── memory.py
        │   ├── network.py
        │   └── gpu.py
        └── models/
            └── __init__.py
```

## Volontairement non résolu dans agent-001

- transport et protocole exacts Agent → Pi ;
- schéma exact des payloads Agent ;
- format de configuration runtime ;
- méthode de service/déploiement ;
- cadence d’échantillonnage et d’envoi ;
- responsabilité et rétention de l’historique.

Ces décisions doivent être documentées avant implémentation et préserver le Raspberry Pi comme point central de normalisation et de publication MQTT.
