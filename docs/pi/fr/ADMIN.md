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
- le processus Web reste non privilégié ; l’installation des mises à jour est déléguée à un `pulsedeck-updater.service` root séparé, déclenché par `pulsedeck-updater.path` ;
- le navigateur ne peut fournir ni commande shell, ni ref Git, ni canal arbitraire : Web Admin peut uniquement mettre en file le canal actif `stable` ou `dev` après détection d’une mise à jour disponible.

Admin V1 utilise HTTP sur le LAN domestique de confiance. Ne pas l’exposer directement à Internet.

## Vues

- Dashboard — état hub, MQTT, système et collectors ;
- Weather — configuration OpenWeather, test fournisseur et hot reload ;
- News — choix NewsAPI/GNews, configuration adaptée au fournisseur et à l’endpoint, test fournisseur et hot reload ;
- Services — catalogue commun des collectors implémentés et prévus ;
- Logs — journaux runtime en mémoire avec filtre par service ; `Tout` est sélectionné par défaut, puis Hub / MQTT / Weather / News / Admin ;
- Mises à jour — état du checker stable/dev et installation d’une mise à jour vérifiée pour le canal actuellement actif ;
- Sécurité — changement du mot de passe administrateur.

## Logs runtime

La vue Logs expose jusqu’à 500 entrées récentes du logging Python du processus `pulsedeck-hub`. Les entrées restent uniquement en RAM et disparaissent au redémarrage du hub ; cette fonction n’ajoute donc aucune écriture microSD. Le filtre par défaut est `Tout`, avec des filtres Hub, MQTT, Weather, News et Admin. La vue s’actualise automatiquement toutes les cinq secondes et peut aussi être rafraîchie manuellement. Elle n’exécute pas `journalctl` et n’accorde aucun accès privilégié au journal système depuis le Web.

## Changements transactionnels

Pour Weather et News, Admin valide les valeurs et teste le fournisseur distant avant d’activer une nouvelle configuration. Les clés NewsAPI et GNews restent séparées afin qu’un changement de fournisseur n’écrase pas l’autre secret. News sépare les champs de requête fournisseur des paramètres runtime PulseDeck : le nombre d’articles mappe vers `pageSize` pour NewsAPI ou `max` pour GNews, la page reste fixée à 1, tandis que la cadence de collecte et le timeout HTTP restent des réglages locaux. Le TOML runtime et les secrets sont écrits atomiquement. Si l’application échoue, PulseDeck tente de restaurer la configuration de travail précédente.

## Chemins runtime

```text
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/openweather_api_key
/etc/pulsedeck/secrets/newsapi_api_key
/etc/pulsedeck/secrets/gnews_api_key
/var/lib/pulsedeck/admin/password.hash
/var/lib/pulsedeck/admin/session.key
```

`pulsedeck-hub.service` conserve `ProtectSystem=strict`. Pour les mises à jour, son privilège se limite à écrire un contrat de demande strict sous `/var/lib/pulsedeck-updater/inbox` ; il ne peut ni écrire le répertoire de statut, ni exécuter directement le worker root.

L’updater privilégié utilise :

```text
/var/lib/pulsedeck-updater/inbox/request.json
/var/lib/pulsedeck-updater/status/status.json
/usr/local/libexec/pulsedeck-updater
/etc/systemd/system/pulsedeck-updater.service
/etc/systemd/system/pulsedeck-updater.path
```

Le worker root n’accepte que des demandes `install` récentes pour `stable` ou `dev`, valide le propriétaire/les permissions du fichier et du lanceur maître root, puis exécute le chemin fixe `pulsedeck --channel <stable|dev> --hub-only --non-interactive`. Le rollback et le cache de releases versionnées restent volontairement reportés.
