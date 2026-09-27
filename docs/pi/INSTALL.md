# Installation Raspberry Pi

## Objectif

L'installation doit devenir reproductible via `scripts/setup_pi.sh`. Le script est conçu pour être idempotent, non interactif et tolérant aux avertissements : il poursuit les contrôles autant que possible et produit un résumé final.

## Patch 0001

Dans `patch_0001`, le script met en place le framework de préflight et de rapport. Il ne modifie pas encore le système et n'installe aucun paquet. L'installation/configuration Mosquitto sera ajoutée dans le patch MQTT suivant.

## Contrôles initiaux

```bash
./scripts/setup_pi.sh --check
```

Le contrôle couvre notamment :
- OS et architecture ;
- kernel et Python ;
- RAM, swap et espace disque ;
- systemd ;
- interface portant la route IPv4 par défaut ;
- adresse IPv4 LAN ;
- état IPv6 à titre informatif ;
- disponibilité du port TCP 1883 ;
- présence éventuelle de Mosquitto.

## Niveaux de résultat

- `[OK]` : conforme ou disponible ;
- `[WARN]` : écart ou prérequis manquant non bloquant ;
- `[FAIL]` : contrôle impossible ou erreur significative ; les autres contrôles continuent si possible.

Le script retourne zéro lorsqu'il n'y a que des avertissements et une valeur non nulle lorsqu'au moins un échec réel a été relevé.

## Politique d'installation future

Le mode d'application n'effectuera pas de mise à jour globale Arch Linux. Seuls les paquets explicitement nécessaires à PulseDeck pourront être installés lors d'un lancement volontaire du script. Aucune suppression automatique de paquet ni réparation opportuniste n'est prévue.
