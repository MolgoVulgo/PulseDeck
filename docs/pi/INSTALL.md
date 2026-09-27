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
