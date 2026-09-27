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
- clé OpenWeather jamais renvoyée en clair ;
- aucune commande système privilégiée exposée dans l’UI V1.

L’interface V1 utilise HTTP sur le LAN domestique. Elle ne doit pas être exposée directement à Internet. Si le périmètre réseau change, HTTPS et le modèle d’authentification devront être réévalués.

## Fonctions V1

Dashboard : version du hub, uptime, état MQTT, état Weather, mémoire et disque disponibles.

Weather : activation/désactivation, clé OpenWeather, géocodage, latitude/longitude, nom affiché, langue, cadences, timeout, test fournisseur et sauvegarde. Une sauvegarde valide recharge le collector Weather dans le même processus sans redémarrage manuel de systemd.

Sécurité : changement du mot de passe administrateur.

## Écriture de configuration

Le TOML runtime reste `/etc/pulsedeck/pulsedeck.toml` et les secrets services restent sous `/etc/pulsedeck/secrets/`. `pulsedeck-hub.service` conserve `ProtectSystem=strict` mais autorise explicitement l’écriture dans `/etc/pulsedeck` et `/var/lib/pulsedeck`. Les permissions Unix limitent ces chemins à `root` et au groupe `pulsedeck`.

Les écritures réalisées par l’UI utilisent un fichier temporaire puis `os.replace()`. Weather est testé avant sauvegarde ; si l’application échoue, l’ancienne configuration est restaurée.
