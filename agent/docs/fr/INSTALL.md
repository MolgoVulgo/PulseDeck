# Installation de PulseDeck Agent

**La version anglaise fait référence.** Version anglaise : [`../INSTALL.md`](../INSTALL.md).

## Résultat commun

Les deux méthodes d'installation fournissent :

- la commande `pulsedeck-agent` ;
- la configuration YAML `/etc/pulsedeck-agent/agent.yml` ;
- l'unité systemd `pulsedeck-agent.service` ;
- le démarrage automatique au boot ;
- les métadonnées du canal source installé (`main` ou `dev`) ;
- `pulsedeck-agent doctor` pour valider complètement l'installation ;
- `pulsedeck-agent update` pour les mises à jour normales sur le même canal.

La configuration par défaut active CPU, MEMORY et NETWORK et laisse GPU désactivé. Les méthodes sont mutuellement exclusives : Arch Linux et les systèmes basés sur pacman utilisent le paquet, tandis que l'installateur standalone est réservé aux systèmes Linux non-Arch.

## Méthode 1 — Arch Linux / makepkg

Prérequis : utilisateur de build non-root, `base-devel`/`makepkg`, Git et sudo configuré pour les opérations pacman.

### Canal stable (`main`)

```bash
git clone https://github.com/MolgoVulgo/PulseDeck.git
cd PulseDeck/agent/packaging/arch
./install.sh
```

### Canal développement (`dev`)

```bash
git clone --branch dev https://github.com/MolgoVulgo/PulseDeck.git
cd PulseDeck/agent/packaging/arch
./install.sh
```

Lorsqu'il est exécuté depuis un checkout dont la branche courante est `main` ou `dev`, `./install.sh` utilise automatiquement cette branche. Le canal peut aussi être choisi explicitement depuis n'importe lequel des deux checkouts :

```bash
./install.sh main
./install.sh dev
```

Le wrapper exécute `makepkg -Csi`, active/démarre `pulsedeck-agent.service`, puis lance `pulsedeck-agent doctor`. Ne pas exécuter le wrapper ni `makepkg` en root.

Le paquet enregistre :

```text
/usr/share/pulsedeck-agent/install-method
/usr/share/pulsedeck-agent/source-ref
/usr/share/pulsedeck-agent/source-revision
```

Pour vérifier à tout moment ce qui est installé :

```bash
pulsedeck-agent version
```

Exemple :

```text
PulseDeck Agent 0.1.0
install: arch-package
channel: dev
revision: 0123456789abcdef...
```

Mise à jour normale :

```bash
pulsedeck-agent update
```

Un Agent installé depuis `dev` reste sur `dev` ; un Agent installé depuis `main` reste sur `main`. La mise à jour se termine par `pulsedeck-agent doctor`.

## Méthode 2 — installateur standalone (Linux non-Arch uniquement)

Cette méthode est réservée aux systèmes Linux qui ne sont pas basés sur Arch/pacman. Sur Arch Linux ou un système compatible basé sur pacman, `install.sh` s'arrête sans modifier la machine et indique la procédure paquet.

Bootstrap distant stable :

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/agent/scripts/install.sh \
  | sudo bash
```

Bootstrap distant développement :

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/dev/agent/scripts/install.sh \
  | sudo bash -s -- --ref dev
```

Depuis un checkout existant des sources PulseDeck :

```bash
sudo ./agent/scripts/install.sh --source "$PWD"
```

Si la branche du checkout vaut `main` ou `dev`, l'installateur standalone enregistre automatiquement ce canal sauf si `--ref` est fourni explicitement.

La méthode standalone installe un environnement Python isolé sous `/opt/pulsedeck-agent`, expose `/usr/local/bin/pulsedeck-agent`, installe l'unité systemd, préserve une configuration YAML existante et démarre le service.

Mise à jour normale :

```bash
pulsedeck-agent update
```

L'updater réutilise le canal enregistré lors de l'installation.

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

Après une modification de configuration :

```bash
pulsedeck-agent config validate
sudo systemctl restart pulsedeck-agent.service
pulsedeck-agent doctor
```

## Vérifier que l'installation est correcte

Exécuter :

```bash
pulsedeck-agent doctor
```

Une installation mini-serveur correcte doit ressembler à :

```text
PulseDeck Agent doctor

Version       : 0.1.0
Install       : arch-package
Channel       : dev
Revision      : 0123456789abcdef...
Agent ID      : mini-server

Configuration : OK
CPU           : OK
Memory        : OK
Network       : OK (enp1s0)
GPU           : disabled
Service       : active
Autostart     : enabled
Snapshot      : OK (age 0.4s)

Result: OK
```

Le code retour vaut `0` uniquement si tous les contrôles obligatoires passent :

```bash
pulsedeck-agent doctor
echo $?
```

Si `Result: FAILED` apparaît, la ligne en échec indique la zone à diagnostiquer. `pulsedeck-agent status`, `systemctl status pulsedeck-agent.service` et `journalctl -u pulsedeck-agent.service` restent disponibles pour un diagnostic plus ciblé.

## Désinstallation standalone

```bash
sudo /usr/local/libexec/pulsedeck-agent/uninstall.sh
```

La configuration et l'état sont conservés par défaut. Pour les supprimer aussi :

```bash
sudo /usr/local/libexec/pulsedeck-agent/uninstall.sh --purge
```

Une installation Arch doit être désinstallée avec pacman et non avec l'outil standalone.
