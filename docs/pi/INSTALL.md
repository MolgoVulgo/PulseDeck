# Installation Raspberry Pi

## Objectif

L'installation du socle Pi est pilotée par `scripts/setup_pi.sh`. Le script est idempotent, poursuit les contrôles indépendants après un avertissement ou un échec local et produit un résumé final.

## Préflight sans modification

```bash
./scripts/setup_pi.sh --check
```

Le contrôle couvre notamment :
- OS, architecture, kernel et Python ;
- RAM, swap et espace disque ;
- systemd ;
- interface portant la route IPv4 par défaut ;
- adresse IPv4 LAN ;
- état IPv6 à titre informatif ;
- disponibilité/occupation du port TCP 1883 ;
- présence de Mosquitto ;
- configuration et état du broker lorsqu'il est déjà installé.

Les avertissements ne rendent pas le préflight bloquant. Une erreur réelle incrémente le compteur `Failures` et donne un code retour non nul, mais les contrôles indépendants suivants continuent autant que possible.

## Installation / configuration MQTT

Le mode application nécessite root :

```bash
sudo ./scripts/setup_pi.sh
```

Le script :
1. détecte l'IPv4 de l'interface portant la route par défaut ;
2. installe `mosquitto` avec `pacman -S --needed --noconfirm` si nécessaire ;
3. n'exécute jamais `pacman -Sy` ni `pacman -Syu` ;
4. conserve le fichier principal Mosquitto et y ajoute uniquement un `include_dir` PulseDeck s'il n'en existe aucun ;
5. crée un drop-in `pulsedeck.conf` lié à l'IPv4 LAN détectée ;
6. active la persistence Mosquitto ;
7. valide la configuration avec `mosquitto --test-config` lorsque cette option est disponible ;
8. active/redémarre `mosquitto.service` ;
9. vérifie le bind du port 1883 ;
10. exécute un smoke test QoS 1 + retained + persistence après redémarrage ;
11. supprime le topic de test retained en fin de validation.

## Fichiers système gérés

Le template versionné est :

```text
config/mosquitto/pulsedeck.conf.in
```

L'installation rend ce template dans un fichier `pulsedeck.conf` sous l'`include_dir` Mosquitto actif. Si aucun `include_dir` n'est déclaré, le script utilise `/etc/mosquitto/conf.d` et ajoute cette inclusion au fichier principal.

Avant cette modification du fichier principal, une sauvegarde unique est créée :

```text
/etc/mosquitto/mosquitto.conf.pulsedeck-before-include
```

Un `pulsedeck.conf` préexistant qui ne contient pas le marqueur PulseDeck n'est pas écrasé.

## Relance

Le script peut être relancé. Les fichiers déjà conformes ne sont pas réécrits inutilement et le paquet Mosquitto n'est pas réinstallé s'il est déjà présent.
