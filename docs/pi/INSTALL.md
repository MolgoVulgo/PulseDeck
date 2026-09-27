# Installation Raspberry Pi

## Deux modes supportés

Le Raspberry Pi de production n'est pas supposé contenir le dépôt de développement PulseDeck.

### Mode A — dépôt présent

Si le dépôt a volontairement été cloné/copied sur le Pi :

```bash
cd /chemin/vers/PulseDeck
sudo ./scripts/setup_pi.sh
```

`setup_pi.sh` délègue le bootstrap système à `scripts/bootstrap_pi.sh`.

### Mode B — bootstrap autonome

Le fichier suivant est autonome :

```text
scripts/bootstrap_pi.sh
```

Il peut être copié seul sur le Pi, sans `git clone`, sans `PROJECT_SCHEMA.md`, sans configuration PulseDeck locale et sans autre fichier du dépôt.

Exemple :

```bash
chmod +x bootstrap_pi.sh
./bootstrap_pi.sh --check
sudo ./bootstrap_pi.sh
```

Le script embarque directement la configuration Mosquitto V1 qu'il doit rendre. Il ne dépend pas de `config/mosquitto/pulsedeck.conf.in`.

## Comportement

Le bootstrap :

- détecte OS, architecture, ressources et IPv4 LAN ;
- vérifie le port TCP 1883 ;
- installe `mosquitto` uniquement s'il manque ;
- n'exécute jamais `pacman -Sy` ni `pacman -Syu` ;
- configure un listener sur l'IPv4 LAN détectée ;
- active anonymous, sans ACL ni TLS pour la V1 LAN ;
- active la persistence Mosquitto ;
- valide la configuration ;
- active/démarre le service ;
- teste QoS 1, retained et restauration après redémarrage ;
- continue autant que possible en présence de warnings et produit un résumé final.

## Mode contrôle

```bash
./bootstrap_pi.sh --check
```

Ce mode n'installe rien, ne modifie aucun fichier et ne redémarre aucun service.

## Principe de déploiement

Le bootstrap prépare l'hôte. Le déploiement futur du service applicatif `pulsedeck-hub` sera traité séparément ; il ne faut pas considérer le dépôt de développement comme un prérequis permanent du Raspberry Pi.

## Validation réelle sur `bluebox`

Le 27 septembre 2026, le bootstrap a été exécuté sur la cible réelle `bluebox` :

- Raspberry Pi 3 Model B Plus Rev 1.3 / Arch Linux ARM `armv7l` ;
- kernel `6.18.33-4-rpi` ;
- Python `3.14.5` ;
- IPv4 LAN `192.168.0.250/24` sur `enu1u1u1` ;
- IPv6 globale absente ;
- Mosquitto `2.1.2-2` installé ;
- listener unique observé sur `192.168.0.250:1883` ;
- QoS 1 retained validé ;
- retained restauré après redémarrage du broker ;
- service systemd activé et démarré ;
- zéro échec ; seul avertissement restant : absence de swap, acceptée pour la V1.

Le bootstrap est non interactif pour l'installation des paquets : il utilise explicitement `pacman --noconfirm -S --needed` et n'exécute jamais `pacman -Sy`/`-Syu`.

## Déploiement autonome du hub — patch 0003

Le service applicatif n'impose pas non plus de clone Git sur le Pi. Copier uniquement :

```text
deploy_hub.sh
```

Puis :

```bash
chmod +x deploy_hub.sh
./deploy_hub.sh --check
sudo ./deploy_hub.sh
```

Le déployeur embarque le paquet Python du hub, la configuration initiale et l'unité systemd. Il crée un venv dédié et installe uniquement les dépendances Python du hub dans ce venv.

Layout runtime retenu :

```text
/opt/pulsedeck/hub            sources applicatives gérées
/opt/pulsedeck/venv           environnement Python
/etc/pulsedeck/pulsedeck.toml configuration runtime
/var/lib/pulsedeck            état runtime
/etc/systemd/system/pulsedeck-hub.service
```

Utilisateur de service : `pulsedeck`.

La configuration runtime existante n'est pas écrasée lors d'un redéploiement. Le premier déploiement y inscrit l'IPv4 LAN détectée comme broker MQTT.
