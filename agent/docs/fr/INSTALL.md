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

Lancer l’installateur avec un utilisateur normal, jamais en root. Il authentifie `sudo` une seule fois au début et maintient cette autorisation pendant toute l’installation. Les prérequis de build Arch manquants (`base-devel` et Git) sont installés automatiquement si nécessaire. Le paquet est construit sans `makepkg -i`, puis installé explicitement avec `pacman -U --noconfirm` : le chemin normal ne provoque donc ni seconde demande de mot de passe ni question de confirmation pacman.

### Canal stable (`main`) — une commande

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/main/agent/packaging/arch/install.sh \
  | bash
```

### Canal développement (`dev`) — une commande

```bash
curl -fsSL \
  https://raw.githubusercontent.com/MolgoVulgo/PulseDeck/dev/agent/packaging/arch/install.sh \
  | bash -s -- dev
```

Depuis un checkout PulseDeck existant, la commande équivalente est simplement :

```bash
./agent/packaging/arch/install.sh
```

Si ce script local se trouve sur `main` ou `dev`, il utilise automatiquement la branche courante. Le canal peut aussi être indiqué explicitement :

```bash
./agent/packaging/arch/install.sh main
./agent/packaging/arch/install.sh dev
```

Le checkout local sert uniquement à sélectionner le canal. Le paquet est toujours construit depuis un nouveau clone temporaire du dépôt distant : un checkout local sale, un ancien répertoire de build ou un `PKGBUILD` modifié localement ne peut donc pas contaminer l’installation. L’installateur résout le canal distant vers un commit précis et transmet ce commit au `PKGBUILD` ; le paquet construit et son `source-revision` enregistré correspondent ainsi à la même révision source.

Après un build réussi, l’installateur masque uniquement la ligne bénigne connue `libfakeroot internal error: payload not recognized!` ; si makepkg échoue réellement, sa sortie d’erreur non filtrée est affichée. L’installateur prépare ensuite le compte système fixe `pulsedeck-agent` et son répertoire d’état, recharge systemd, active/redémarre `pulsedeck-agent.service`, puis lance `pulsedeck-agent doctor`. Si le contrôle final échoue, l’installateur affiche automatiquement l’état du service, les dernières entrées du journal et l’identité installée avant de retourner un code d’échec.

Le paquet enregistre :

```text
/usr/share/pulsedeck-agent/install-method
/usr/share/pulsedeck-agent/source-ref
/usr/share/pulsedeck-agent/source-revision
```

Pour vérifier l’identité installée :

```bash
pulsedeck-agent version
```

La mise à jour normale tient en une commande :

```bash
pulsedeck-agent update
```

Un Agent installé depuis `dev` reste sur `dev` ; un Agent installé depuis `main` reste sur `main`. Les mises à jour réutilisent le même chemin de build distant propre et se terminent par `pulsedeck-agent doctor`.

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

La méthode standalone installe un environnement Python isolé sous `/opt/pulsedeck-agent`, expose `/usr/local/bin/pulsedeck-agent`, crée le compte système fixe `pulsedeck-agent` via `systemd-sysusers`, installe l'unité systemd, préserve une configuration YAML existante et démarre le service.

Mise à jour normale :

```bash
pulsedeck-agent update
```

L'updater réutilise le canal enregistré lors de l'installation.

## Compte de service et état local

Le service s'exécute avec le compte système fixe `pulsedeck-agent`. Le répertoire d'état est `/var/lib/pulsedeck-agent` en mode `0755` ; les fichiers runtime comme `snapshot.json` sont écrits en `0644`. Un utilisateur normal peut donc exécuter `pulsedeck-agent doctor` sans `sudo`, tandis que seul le compte de service écrit l'état Agent.

Lors d'une mise à jour depuis l'ancien jet utilisant `DynamicUser=yes`, l'ancien état diagnostique privé sous `/var/lib/private/pulsedeck-agent` est automatiquement supprimé puis un répertoire d'état propre est recréé. Le snapshot reste uniquement un état diagnostique ; il ne constitue ni un historique ni le contrat de payload Agent -> Pi.

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
transport:
  enabled: true
  listen: 0.0.0.0
  port: 8765
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
transport:
  enabled: true
  listen: 0.0.0.0
  port: 8765
```

Le transport HTTP est désactivé par défaut dans l’exemple versionné. L’activer sur les machines supervisées avant leur ajout dans PulseDeck Admin. `listen: 0.0.0.0` accepte toutes les interfaces locales ; utiliser une adresse LAN précise pour limiter davantage l’écoute.

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
State dir     : OK (pulsedeck-agent:pulsedeck-agent 0755)
Snapshot      : OK (age 0.4s)
Transport     : OK (127.0.0.1:8765; health + snapshot age 0.4s)

Result: OK
```

Lorsque le transport est activé, `doctor` teste `/v1/health` et `/v1/snapshot` et valide les capacités obligatoires `cpu`/`memory`/`network` ; pour une écoute wildcard `0.0.0.0`, la connexion locale utilise `127.0.0.1`. Le code retour vaut `0` uniquement si tous les contrôles obligatoires passent :

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
