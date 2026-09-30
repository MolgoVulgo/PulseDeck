# PulseDeck Agent

**La version anglaise fait référence.** Version anglaise : [`README.md`](README.md).

PulseDeck Agent est le composant de métriques local aux PC et serveurs supervisés. Il collecte la télémétrie de la machine et est destiné à l'envoyer au Raspberry Pi, qui reste le hub PulseDeck central, le normaliseur et le producteur MQTT orienté affichage.

`agent-004-1` conserve le contrat de build propre de `agent-004` et durcit l’expérience Arch : sudo est authentifié une seule fois, le paquet est construit sans installation pilotée par makepkg, l’installation pacman est non interactive et la validation post-installation reste automatique. À partir de `patch_0021`, le transport Agent -> Pi V1 est un endpoint HTTP en lecture seule sur le LAN de confiance. Il est désactivé par défaut et utilise une adresse d’écoute et un port configurables (port `8765` par défaut).

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

Le premier backend GPU reprend l'approche Linux AMD/sysfs de PulseMon. Le caractère optionnel du GPU est un contrat V1 ; la prise en charge d'autres constructeurs GPU n'est pas encore définie.

## Commandes

```text
pulsedeck-agent version
pulsedeck-agent config path
pulsedeck-agent config validate
pulsedeck-agent check
pulsedeck-agent snapshot
pulsedeck-agent status
pulsedeck-agent doctor
pulsedeck-agent update
```

`version` affiche la méthode d'installation, le canal source et la révision source. `doctor` est la commande normale de validation après installation et après mise à jour. Elle contrôle les métadonnées d'installation, le YAML, CPU/MEMORY/NETWORK, le GPU optionnel, l'état systemd actif/activé, le propriétaire/mode du répertoire d'état et le snapshot local. Lorsque le transport HTTP est activé, elle teste aussi localement `/v1/health` et `/v1/snapshot` et valide le schéma réseau, l'identité Agent, les capacités obligatoires, la santé et la fraîcheur du snapshot. Le code retour `0` signifie que le diagnostic complet est valide.

Le service systemd exécute :

```text
pulsedeck-agent run
```

`run` effectue toujours la collecte locale et maintient atomiquement :

```text
/var/lib/pulsedeck-agent/snapshot.json
```

Ce fichier et la commande `snapshot` restent un état interne/diagnostique de l’Agent. Lorsque le transport HTTP est activé, l’Agent expose séparément `GET /v1/snapshot` avec le schéma réseau 1 (`protocol=pulsedeck-agent-http`) ; le Pi ne lit jamais `snapshot.json` à distance.

## Installation

Deux chemins mutuellement exclusifs sont définis :

1. Arch Linux / systèmes basés sur pacman : construction du paquet via `agent/packaging/arch/install.sh` et `makepkg` ;
2. systèmes Linux non-Arch : installateur standalone `agent/scripts/install.sh` uniquement.

Sur Arch, l’installateur construit toujours le paquet depuis un checkout distant temporaire et propre du canal sélectionné. L’état d’un checkout local existant, y compris ses modifications non commitées, ne peut donc pas influencer le paquet construit. Depuis un checkout, la commande normale reste :

```bash
./agent/packaging/arch/install.sh
```

Elle utilise automatiquement la branche Git courante lorsqu’elle vaut `main` ou `dev` ; sinon elle utilise `main`. Le canal peut aussi être donné explicitement :

```bash
./agent/packaging/arch/install.sh main
./agent/packaging/arch/install.sh dev
```

Un bootstrap distant en une commande est documenté dans `docs/fr/INSTALL.md`. L’installateur résout une révision Git précise, épingle le build du paquet sur cette révision, authentifie sudo une seule fois, construit avec l’utilisateur normal, installe le paquet produit via pacman non interactif, redémarre le service puis lance `pulsedeck-agent doctor`. Le canal sélectionné est enregistré avec l’Agent installé. `pulsedeck-agent update` reste sur ce même canal et réutilise le même chemin de build propre.

L'installateur standalone refuse explicitement Arch/pacman afin d'éviter de mélanger fichiers gérés par pacman et installation standalone.

Le service systemd s'exécute avec le compte système fixe `pulsedeck-agent`. Son répertoire d'état `/var/lib/pulsedeck-agent` reste modifiable uniquement par le service, tandis que les fichiers diagnostiques comme `snapshot.json` sont lisibles par les utilisateurs normaux afin que `pulsedeck-agent doctor` ne nécessite pas root.

Les deux méthodes lancent automatiquement `pulsedeck-agent doctor` après le démarrage normal du service. La commande peut toujours être relancée manuellement :

```bash
pulsedeck-agent doctor
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
    ├── http_server.py
    ├── metadata.py
    └── runtime.py
```

## Transport Agent -> Pi

La V1 utilise HTTP en lecture seule sur le LAN de confiance. Configurer `transport.enabled`, `transport.listen` et `transport.port` dans `/etc/pulsedeck-agent/agent.yml`. L’Agent expose `GET /v1/health` pour les contrôles locaux/opérationnels et `GET /v1/snapshot` pour le Pi. Avec `listen: 0.0.0.0`, `pulsedeck-agent doctor` teste le service via `127.0.0.1` ; l’adresse wildcard n’est jamais utilisée comme destination de connexion. L’adresse de la machine supervisée est configurée côté Pi ; elle n’est intégrée ni au code Agent ni au code hub. L’endpoint ne doit pas être exposé directement à Internet.

## Toujours non résolu

- responsabilité et rétention de l'historique.

La valeur locale `sample_interval_s` contrôle uniquement l’échantillonnage local ; la cadence d’interrogation du Pi est configurée indépendamment sous `[collectors.machines]`.
