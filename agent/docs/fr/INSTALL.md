# Installation de PulseDeck Agent

**La version anglaise fait référence.** Version anglaise : [`../INSTALL.md`](../INSTALL.md).

## Résultat commun

Les deux méthodes d'installation fournissent :

- la commande `pulsedeck-agent` ;
- la configuration YAML `/etc/pulsedeck-agent/agent.yml` ;
- l'unité systemd `pulsedeck-agent.service` ;
- le démarrage automatique au boot ;
- `pulsedeck-agent update` comme commande normale de mise à jour.

La configuration par défaut active CPU, MEMORY et NETWORK et laisse GPU désactivé. Les méthodes sont mutuellement exclusives : Arch Linux et les systèmes basés sur pacman utilisent le paquet, tandis que l’installateur standalone est réservé aux systèmes Linux non-Arch. `install.sh` refuse les systèmes Arch/pacman.

## Méthode 1 — Arch Linux / makepkg

Prérequis : utilisateur de build non-root, `base-devel`/`makepkg`, Git et sudo configuré pour les opérations pacman.

Depuis un checkout des sources PulseDeck :

```bash
cd agent/packaging/arch
makepkg -si
sudo systemctl enable --now pulsedeck-agent.service
```

Le `PKGBUILD` récupère les sources PulseDeck et package `agent/`. `makepkg` ne doit pas être exécuté en root.

Mise à jour normale :

```bash
pulsedeck-agent update
```

Pour une installation par paquet Arch, l'updater clone les sources PulseDeck courantes et exécute `makepkg -si` avec l'utilisateur non-root appelant.

## Méthode 2 — installateur standalone (Linux non-Arch uniquement)

Cette méthode est réservée aux systèmes Linux qui ne sont pas basés sur Arch/pacman. Sur Arch Linux ou un système compatible basé sur pacman, `install.sh` s’arrête sans modifier la machine et indique la procédure `makepkg`.

Bootstrap distant :

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/agent/scripts/install.sh \
  | sudo bash
```

Depuis un checkout existant des sources PulseDeck :

```bash
sudo ./agent/scripts/install.sh --source "$PWD"
```

La méthode standard installe un environnement Python isolé sous `/opt/pulsedeck-agent`, expose `/usr/local/bin/pulsedeck-agent`, installe l'unité systemd, préserve une configuration YAML existante et démarre le service.

Mise à jour normale :

```bash
pulsedeck-agent update
```

L'updater relance l'installateur standard installé en récupérant la référence source courante. Aucun clone du dépôt n'est requis sur la cible.

## Première configuration

Modifier :

```text
/etc/pulsedeck-agent/agent.yml
```

Exemple mini-serveur :

```yaml
agent:
  id: mini-server
  name: Mini Server
collectors:
  cpu: {}
  memory: {}
  network:
    interface: enp1s0
  gpu:
    enabled: false
runtime:
  sample_interval_s: 1.0
```

Exemple PC gamer :

```yaml
agent:
  id: gaming-pc
  name: Gaming PC
collectors:
  cpu: {}
  memory: {}
  network:
    interface: auto
  gpu:
    enabled: true
runtime:
  sample_interval_s: 1.0
```

Valider puis redémarrer :

```bash
pulsedeck-agent config validate
pulsedeck-agent check
sudo systemctl restart pulsedeck-agent.service
pulsedeck-agent status
```

## Désinstallation standard

```bash
sudo /usr/local/libexec/pulsedeck-agent/uninstall.sh
```

La configuration et l'état sont conservés par défaut. Pour les supprimer aussi :

```bash
sudo /usr/local/libexec/pulsedeck-agent/uninstall.sh --purge
```

Une installation Arch doit être désinstallée avec pacman et non avec l’outil standalone.

Si une ancienne installation standalone de l’Agent existe déjà sur une machine Arch/pacman, la supprimer d’abord avec `/usr/local/libexec/pulsedeck-agent/uninstall.sh`, puis installer le paquet avec `makepkg -si`.
