# Installation Raspberry Pi

> L’anglais fait référence : [`../INSTALL.md`](../INSTALL.md).

## Principe

Le Raspberry Pi est une cible de déploiement. Le dépôt Git PulseDeck n’a pas besoin d’y être cloné.

Les scripts suivent trois règles :

1. tout ce qui peut être détecté ou configuré de façon déterministe est automatisé ;
2. la configuration fonctionnelle des services passe par PulseDeck Admin, pas par les questions de l’installateur ;
3. chaque script est relançable et fournit un mode `--check` sans modification.

## Première installation

La seule commande utilisateur nécessaire sur un Raspberry Pi neuf est :

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/install.sh \
  | sudo bash
```

`install.sh` reste volontairement minimal. Il :

1. télécharge `scripts/pulsedeck.sh` depuis la référence Git sélectionnée ;
2. valide sa syntaxe Bash avant installation ;
3. l’installe sous `/usr/local/sbin/pulsedeck` ;
4. initialise `/var/lib/pulsedeck/installer/scripts/pulsedeck.sh` ;
5. lance immédiatement le lanceur maître installé.

Le lanceur maître rafraîchit ensuite les scripts de travail et réalise l’installation complète normale. Le dépôt Git n’a pas besoin d’être cloné sur le Pi.

Pour un contrôle sans modification pendant le bootstrap :

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/install.sh \
  | sudo bash -s -- --check
```

Pour installer uniquement le lanceur persistant sans démarrer le déploiement :

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/scripts/install.sh \
  | sudo bash -s -- --install-only
```

## Lanceur maître persistant

Après ce bootstrap initial, le point d’entrée normal est toujours :

```bash
sudo pulsedeck
```

Variantes utiles :

```bash
pulsedeck --check
sudo pulsedeck --hub-only
sudo pulsedeck --bootstrap-only
sudo pulsedeck --offline --hub-only
```

Le lanceur maître vérifie sur GitHub `pulsedeck.sh`, `setup_pi.sh`, `bootstrap_pi.sh` et `deploy_hub.sh`, valide leur syntaxe shell, ne remplace que les copies modifiées sous `/var/lib/pulsedeck/installer/scripts/`, puis exécute le worker `setup_pi.sh` rafraîchi. `--offline` désactive explicitement ce rafraîchissement et utilise le cache.

`setup_pi.sh` reste l’orchestrateur complet interne. Il peut toujours être lancé directement pour le développement ou le diagnostic, mais l’utilisateur n’a plus besoin de le télécharger manuellement.

Options principales :

```text
--check              contrôler sans modifier la cible
--verbose            afficher davantage de diagnostics
--bootstrap-only     installer/contrôler uniquement le socle MQTT
--hub-only           installer/contrôler uniquement pulsedeck-hub
--non-interactive    ne jamais demander de saisie manuelle
--ref REF            branche/tag/commit Git utilisé pour les téléchargements
--offline            maître uniquement : utiliser le cache sans rafraîchir GitHub
```

## `bootstrap_pi.sh`

Le bootstrap contrôle l’hôte, détecte l’IPv4 LAN, installe Mosquitto si nécessaire, configure le listener IPv4, active la persistence et valide QoS 1 / retained. Il n’exécute jamais `pacman -Sy` ni `pacman -Syu`.

## `deploy_hub.sh`

Le déployeur du hub :

- crée/réutilise le compte système `pulsedeck` ;
- installe l’application dans `/opt/pulsedeck/hub` ;
- crée/réutilise `/opt/pulsedeck/venv` ;
- installe les dépendances Python dans ce venv ;
- masque les détails pip/build en mode normal et n’affiche que le statut de l’étape ; la sortie détaillée n’apparaît qu’avec `--verbose` ;
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
