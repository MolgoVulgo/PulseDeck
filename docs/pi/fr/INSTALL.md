# Installation Raspberry Pi

> L’anglais fait référence : [`../INSTALL.md`](../INSTALL.md).

## Principe

Le Raspberry Pi est une cible de déploiement. Le dépôt Git PulseDeck n’a pas besoin d’y être cloné.

Les scripts suivent trois règles :

1. tout ce qui peut être détecté ou configuré de façon déterministe est automatisé ;
2. la configuration fonctionnelle des services passe par PulseDeck Admin, pas par les questions de l’installateur ;
3. chaque script est relançable et fournit un mode `--check` sans modification.

## Point d’entrée recommandé

Le lanceur maître persistant **`pulsedeck`** devient le point d’entrée normal après la première installation. `setup_pi.sh` reste l’orchestrateur de travail utilisé par ce lanceur. Une cible neuve nécessite un seul téléchargement initial de `setup_pi.sh` ; les mises à jour suivantes n’en ont plus besoin.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/setup_pi.sh \
  -o setup_pi.sh
chmod +x setup_pi.sh

./setup_pi.sh --check
sudo ./setup_pi.sh
```

Le script autonome récupère `bootstrap_pi.sh` et `deploy_hub.sh` depuis GitHub lorsqu’ils ne sont pas présents localement. Le clone du dépôt reste facultatif.

Lors d’un déploiement en mode application, `deploy_hub.sh` installe `/usr/local/sbin/pulsedeck`. Ensuite :

```bash
pulsedeck --check
sudo pulsedeck
sudo pulsedeck --hub-only
```

Le lanceur maître vérifie sur GitHub `pulsedeck.sh`, `setup_pi.sh`, `bootstrap_pi.sh` et `deploy_hub.sh`, valide leur syntaxe shell, ne remplace que les copies de cache modifiées sous `/var/lib/pulsedeck/installer/scripts/`, puis exécute le worker `setup_pi.sh` rafraîchi. `--offline` désactive explicitement le rafraîchissement GitHub et utilise le cache.

Options principales :

```text
--check              contrôler sans modifier la cible
--verbose            afficher davantage de diagnostics
--bootstrap-only     installer/contrôler uniquement le socle MQTT
--hub-only           installer/contrôler uniquement pulsedeck-hub
--non-interactive    ne jamais demander de saisie manuelle
--source-dir DIR     utiliser les scripts spécialisés locaux de DIR
--ref REF            branche/tag/commit Git utilisé pour les téléchargements
```

## `bootstrap_pi.sh`

Le bootstrap contrôle l’hôte, détecte l’IPv4 LAN, installe Mosquitto si nécessaire, configure le listener IPv4, active la persistence et valide QoS 1 / retained. Il n’exécute jamais `pacman -Sy` ni `pacman -Syu`.

## `deploy_hub.sh`

Le déployeur du hub :

- crée/réutilise le compte système `pulsedeck` ;
- installe l’application dans `/opt/pulsedeck/hub` ;
- crée/réutilise `/opt/pulsedeck/venv` ;
- installe les dépendances Python dans ce venv ;
- crée ou conserve `/etc/pulsedeck/pulsedeck.toml` ;
- prépare `/etc/pulsedeck/secrets/` ;
- active PulseDeck Admin sur l’IPv4 LAN détectée, port `8080` ;
- installe/met à jour le lanceur maître persistant `/usr/local/sbin/pulsedeck` ;
- installe et redémarre `pulsedeck-hub.service` ;
- valide l’état runtime.

La configuration fonctionnelle des collectors n’est pas demandée par le déployeur. Weather, News et les futurs services se configurent dans PulseDeck Admin.

Layout runtime :

```text
/opt/pulsedeck/hub
/opt/pulsedeck/venv
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/
/var/lib/pulsedeck
/var/lib/pulsedeck/installer/scripts
/usr/local/sbin/pulsedeck
/etc/systemd/system/pulsedeck-hub.service
```

## Web Admin après installation

Ouvrir :

```text
http://<IPv4-LAN-du-Pi>:8080
```

Lors du premier déploiement Web, l’installateur crée les identifiants locaux `admin` et affiche une seule fois le mot de passe initial. Les mises à jour suivantes conservent les identifiants existants.

## Mises à jour ciblées

```bash
sudo pulsedeck --hub-only
sudo pulsedeck --bootstrap-only
pulsedeck --check --verbose
```

Une mise à jour normale du hub conserve les réglages et secrets runtime des collectors.
