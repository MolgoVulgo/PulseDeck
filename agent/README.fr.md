# PulseDeck Agent

**La version anglaise fait référence.** Version anglaise : [`README.md`](README.md).

PulseDeck Agent est le composant de métriques local aux PC et serveurs supervisés. Il collecte la télémétrie de la machine et est destiné à l'envoyer au Raspberry Pi, qui reste le hub PulseDeck central, le normaliseur et le producteur MQTT orienté affichage.

`agent-002` constitue le premier jet exécutable. Il implémente la collecte locale, la configuration YAML, un runtime systemd, le packaging Arch via `makepkg`, un installateur standard et une commande de mise à jour commune. Le transport Agent -> Pi reste volontairement non implémenté tant que ce contrat n'est pas défini.

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

Métriques :

- CPU : utilisation, température, puissance si disponible ;
- MEMORY : octets utilisés, octets totaux, pourcentage d'utilisation ;
- NETWORK : interface sélectionnée, débits RX/TX et compteurs RX/TX ;
- GPU lorsqu'il est activé : utilisation, température, puissance, fréquences core/mémoire, VRAM utilisée/totale et ventilation si disponible.

Une télémétrie optionnelle indisponible reste invalide/null ; elle n'est jamais synthétisée à zéro.

## Configuration

La configuration runtime est en YAML :

```text
/etc/pulsedeck-agent/agent.yml
```

Exemple versionné : [`config/pulsedeck-agent.example.yml`](config/pulsedeck-agent.example.yml).

CPU, MEMORY et NETWORK ne peuvent pas être désactivés en V1. `collectors.network.interface: auto` résout si possible l'interface portant la route par défaut. Le GPU est activé uniquement avec `collectors.gpu.enabled: true`.

Le premier backend GPU reprend l'approche Linux AMD/sysfs de PulseMon. Le caractère optionnel du GPU est un contrat V1 ; la prise en charge d'autres constructeurs GPU n'est pas définie par `agent-002`.

## Commandes

```text
pulsedeck-agent version
pulsedeck-agent config path
pulsedeck-agent config validate
pulsedeck-agent check
pulsedeck-agent snapshot
pulsedeck-agent status
pulsedeck-agent update
```

Le service systemd exécute :

```text
pulsedeck-agent run
```

Tant que le transport Agent -> Pi n'est pas défini, `run` effectue la collecte locale et maintient atomiquement :

```text
/var/lib/pulsedeck-agent/snapshot.json
```

Ce fichier et la commande `snapshot` sont un état interne/diagnostique de l'Agent, pas le futur contrat de payload Agent -> Pi.

## Installation

Deux chemins mutuellement exclusifs sont définis :

1. Arch Linux / systèmes basés sur pacman : paquet construit avec `makepkg -si` uniquement ;
2. systèmes Linux non-Arch : installateur standalone `agent/scripts/install.sh` uniquement.

`install.sh` refuse explicitement de s’exécuter sur Arch/pacman afin d’éviter de mélanger des fichiers gérés par pacman et une installation standalone. Les deux chemins utilisent les mêmes sources `agent/`, installent la même commande et le même service systemd. La mise à jour utilise une commande utilisateur unique :

```bash
pulsedeck-agent update
```

Voir [`docs/fr/INSTALL.md`](docs/fr/INSTALL.md).

## Organisation des sources

```text
agent/
├── pyproject.toml
├── config/
├── docs/
├── packaging/arch/
├── scripts/
├── systemd/
├── tests/
└── src/pulsedeck_agent/
    ├── collectors/
    ├── models/
    ├── cli.py
    ├── config.py
    └── runtime.py
```

## Toujours non résolu

- transport et protocole exacts Agent -> Pi ;
- schéma exact du payload Agent -> Pi ;
- responsabilité et rétention de l'historique.

La valeur locale `sample_interval_s` est uniquement un réglage d'implémentation de l'Agent ; elle ne définit pas la future cadence de collecte/publication du Pi.
