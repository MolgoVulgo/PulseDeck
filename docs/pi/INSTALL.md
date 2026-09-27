# Installation Raspberry Pi

## Principe

Le Raspberry Pi est une cible de déploiement : le dépôt PulseDeck n'a pas besoin d'y être cloné.

L'installation par scripts suit trois règles :

1. tout ce qui peut être détecté ou configuré automatiquement l'est sans intervention ;
2. une question n'est posée que lorsqu'une information ne peut pas être déterminée proprement ou lorsqu'un choix manuel est nécessaire ;
3. chaque script reste relançable et fournit un mode `--check` sans modification.

## `setup_pi.sh` — installation complète

C'est le point d'entrée recommandé.

Il enchaîne :

```text
préflight
  ↓
bootstrap_pi.sh
  ├── contrôles système
  ├── installation/configuration Mosquitto
  └── tests MQTT
  ↓
deploy_hub.sh
  ├── utilisateur/runtime PulseDeck
  ├── venv Python
  ├── installation pulsedeck-hub
  ├── configuration
  ├── systemd
  └── validation MQTT availability
  ↓
résumé final
```

Téléchargement direct depuis GitHub :

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/setup_pi.sh \
  -o setup_pi.sh
chmod +x setup_pi.sh
```

Diagnostic complet :

```bash
./setup_pi.sh --check
```

Installation complète :

```bash
sudo ./setup_pi.sh
```

Si `setup_pi.sh` est utilisé hors dépôt, il récupère automatiquement `bootstrap_pi.sh` et `deploy_hub.sh` depuis GitHub. Si ces fichiers sont disponibles localement, les copies locales sont utilisées.

Options principales :

```text
--check              aucune modification
--verbose            diagnostics supplémentaires
--bootstrap-only     socle MQTT uniquement
--hub-only           hub uniquement
--non-interactive    ne poser aucune question
--source-dir DIR     utiliser les scripts spécialisés depuis DIR
--ref REF            branche/tag GitHub à utiliser
```

En mode application, si le script n'est pas lancé comme root et que `sudo` est disponible, il se relance automatiquement via `sudo`.

## `bootstrap_pi.sh` — socle système/MQTT

Ce script est autonome. Il sert lorsque seul le socle MQTT doit être installé, contrôlé ou réparé.

```bash
./bootstrap_pi.sh --check
sudo ./bootstrap_pi.sh
```

Il :

- contrôle OS, architecture, Python, RAM, disque et réseau ;
- détecte l'IPv4 LAN ;
- installe Mosquitto s'il manque ;
- n'exécute jamais `pacman -Sy` ni `pacman -Syu` ;
- configure le listener MQTT LAN IPv4 ;
- active persistence, anonymous V1, sans ACL/TLS ;
- active/démarre Mosquitto ;
- teste QoS 1, retained et restauration après redémarrage ;
- produit un résumé final.

## `deploy_hub.sh` — service applicatif

Ce script est également autonome. Il suppose que le socle MQTT est déjà opérationnel.

```bash
./deploy_hub.sh --check
sudo ./deploy_hub.sh
```

Il :

- contrôle Python et Mosquitto ;
- crée l'utilisateur système `pulsedeck` si nécessaire ;
- installe les sources sous `/opt/pulsedeck/hub` ;
- crée/réutilise `/opt/pulsedeck/venv` ;
- installe les dépendances Python dans ce venv ;
- crée la configuration initiale `/etc/pulsedeck/pulsedeck.toml` si elle n'existe pas ;
- conserve une configuration runtime existante ;
- installe et active `pulsedeck-hub.service` ;
- vérifie `pulsedeck/v1/system/availability`.

Layout runtime :

```text
/opt/pulsedeck/hub
/opt/pulsedeck/venv
/etc/pulsedeck/pulsedeck.toml
/var/lib/pulsedeck
/etc/systemd/system/pulsedeck-hub.service
```

## Questions interactives

L'installation ne demande pas de confirmation pour les opérations attendues après un lancement volontaire de `sudo ./setup_pi.sh`.

Une question est réservée à une situation réellement indéterminée. Par exemple, si un script spécialisé manque et ne peut pas être téléchargé automatiquement, `setup_pi.sh` peut demander son chemin local. Avec `--non-interactive`, aucune question n'est posée et l'étape échoue explicitement à la place.

Les fichiers existants non reconnus comme gérés par PulseDeck ne doivent pas être écrasés silencieusement.

## Dépôt présent sur le Pi

Le même point d'entrée fonctionne depuis un clone :

```bash
cd /chemin/vers/PulseDeck
sudo ./scripts/setup_pi.sh
```

Dans ce cas, les scripts spécialisés du dépôt sont utilisés directement.

## Configuration Weather — OpenWeather One Call 4.0

À partir de `patch_0007`, `deploy_hub.sh` propose de configurer le premier collector Weather lorsqu'il n'est pas encore activé.

En mode interactif, le script demande la clé OpenWeather avec saisie masquée puis le lieu. Le lieu peut être saisi sous forme de coordonnées `latitude,longitude` ou sous forme de ville ; dans ce dernier cas le Geocoding API OpenWeather est utilisé et un choix est demandé seulement en cas d'ambiguïté.

La clé est stockée hors TOML :

```text
/etc/pulsedeck/secrets/openweather_api_key
```

La configuration du collector reste dans :

```text
/etc/pulsedeck/pulsedeck.toml
```

Le déploiement valide ensuite l'accès à One Call 4.0 avant de redémarrer `pulsedeck-hub`. Avec `--non-interactive`, aucune question n'est posée ; Weather reste désactivé tant qu'une configuration complète n'existe pas déjà.

Voir `docs/pi/WEATHER.md` pour le contrat détaillé.
