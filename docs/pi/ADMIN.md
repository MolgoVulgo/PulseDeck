# PulseDeck Admin V1

PulseDeck Admin est l’interface Web légère intégrée au même processus `pulsedeck-hub`. Aucun service Web séparé n’est ajouté.

## Accès

Le déployeur active l’interface sur l’IPv4 LAN détectée, port `8080` :

```text
http://<IPv4-LAN-du-Pi>:8080
```

Sur la cible de référence actuelle :

```text
http://192.168.0.250:8080
```

Le premier déploiement Web génère un mot de passe administrateur aléatoire et l’affiche une seule fois. L’utilisateur est `admin`. Le hash du mot de passe et la clé de session résident dans `/var/lib/pulsedeck/admin` et ne sont pas versionnés.

## Sécurité V1

- interface liée à l’IPv4 LAN, pas à `0.0.0.0` ;
- authentification obligatoire pour les données et actions d’administration ;
- mot de passe stocké sous forme PBKDF2-SHA256 salée ;
- session HMAC signée, cookie `HttpOnly` et `SameSite=Strict` ;
- garde anti-CSRF et vérification d’origine pour les mutations ;
- en-têtes CSP, anti-frame, no-sniff et no-store ;
- secrets services jamais renvoyés en clair ;
- aucune commande système privilégiée exposée dans l’UI V1.

L’interface V1 utilise HTTP sur le LAN domestique. Elle ne doit pas être exposée directement à Internet. Si le périmètre réseau change, HTTPS et le modèle d’authentification devront être réévalués.

## Navigation et composants

À partir de `patch_0009`, l’interface est organisée en quatre vues :

- **Vue d’ensemble** : Hub, MQTT, Weather, mémoire/disque, activité récente et aperçu des services ;
- **Weather** : configuration complète OpenWeather, test et rechargement du collector ;
- **Services** : catalogue commun des collectors implémentés et planifiés ;
- **Sécurité** : gestion du mot de passe Admin.

Les retours d’action utilisent des notifications homogènes et les formulaires disposent d’une validation locale avant appel API. Les cadences Weather sont présentées en minutes dans l’UI puis converties en secondes pour le contrat runtime existant.

Le catalogue est la base de navigation des prochains collectors. Weather est implémenté. News est planifié avec GNews en HTTPS et authentification fournisseur par header `X-Api-Key`. PC gamer, Printer et Mini serveur restent planifiés sans contrat fournisseur inventé.

## Weather

Weather permet activation/désactivation, clé OpenWeather, géocodage, latitude/longitude, nom affiché, langue, cadences, timeout, test fournisseur et sauvegarde. Une sauvegarde valide recharge le collector Weather dans le même processus sans redémarrage manuel de systemd.

Le dashboard expose la dernière réussite Current/Hourly/Daily, le nombre d’éléments retained attendus et la dernière erreur runtime lorsqu’elle existe. La clé API est représentée uniquement par l’état `configurée/absente`.

## Écriture de configuration

Le TOML runtime reste `/etc/pulsedeck/pulsedeck.toml` et les secrets services restent sous `/etc/pulsedeck/secrets/`. `pulsedeck-hub.service` conserve `ProtectSystem=strict` mais autorise explicitement l’écriture dans `/etc/pulsedeck` et `/var/lib/pulsedeck`. Les permissions Unix limitent ces chemins à `root` et au groupe `pulsedeck`.

Les écritures réalisées par l’UI utilisent un fichier temporaire puis `os.replace()`. Weather est testé avant sauvegarde ; si l’application échoue, l’ancienne configuration est restaurée.
