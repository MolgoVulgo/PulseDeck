# PulseDeck Admin V1

> L’anglais fait référence : [`../ADMIN.md`](../ADMIN.md).

PulseDeck Admin est l’interface Web légère intégrée dans le même processus `pulsedeck-hub`. Aucun service Web séparé n’est ajouté.

## Accès

Le déployeur lie Admin à l’IPv4 LAN détectée sur le port `8080` :

```text
http://<IPv4-LAN-du-Pi>:8080
```

L’utilisateur local est `admin`. Le premier déploiement Web génère un mot de passe initial aléatoire et l’affiche une seule fois. Le hash du mot de passe et la clé de session résident sous `/var/lib/pulsedeck/admin` et ne sont jamais versionnés.

## Sécurité

- interface liée à l’IPv4 LAN et non à `0.0.0.0` ;
- authentification obligatoire pour les données détaillées et les actions d’administration ;
- hash PBKDF2-SHA256 salé ;
- session HMAC signée, cookie `HttpOnly` / `SameSite=Strict` ;
- garde de mutation et vérification same-origin ;
- en-têtes CSP, anti-frame, no-sniff et no-store ;
- les clés API ne sont jamais renvoyées en clair après stockage ;
- aucune commande système privilégiée exposée dans l’UI.

Admin V1 utilise HTTP sur le LAN domestique de confiance. Ne pas l’exposer directement à Internet.

## Vues

- Dashboard — état hub, MQTT, système et collectors ;
- Weather — configuration OpenWeather, test fournisseur et hot reload ;
- News — configuration NewsAPI adaptée à l’endpoint (`top-headlines` ou `everything`), filtres fournisseur documentés, test fournisseur et hot reload ;
- Services — catalogue commun des collectors implémentés et prévus ;
- Sécurité — changement du mot de passe administrateur.

## Changements transactionnels

Pour Weather et News, Admin valide les valeurs et teste le fournisseur distant avant d’activer une nouvelle configuration. News sépare les champs de requête fournisseur des paramètres runtime PulseDeck : `pageSize` correspond au nombre d’articles du snapshot, la page reste fixée à 1, tandis que la cadence de collecte et le timeout HTTP restent des réglages locaux. Le TOML runtime et les secrets sont écrits atomiquement. Si l’application échoue, PulseDeck tente de restaurer la configuration de travail précédente.

## Chemins runtime

```text
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/openweather_api_key
/etc/pulsedeck/secrets/newsapi_api_key
/var/lib/pulsedeck/admin/password.hash
/var/lib/pulsedeck/admin/session.key
```

`pulsedeck-hub.service` conserve `ProtectSystem=strict` tout en autorisant explicitement les écritures sous `/etc/pulsedeck` et `/var/lib/pulsedeck`.
