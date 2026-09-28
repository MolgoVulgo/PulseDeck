# Exploitation Raspberry Pi

> L’anglais fait référence : [`../OPERATIONS.md`](../OPERATIONS.md).

## Contrôles globaux

```bash
pulsedeck --check
pulsedeck --check --verbose
```

`setup_pi.sh` est un worker interne. Son exécution directe reste utile pour certains diagnostics de développement, mais la commande persistante `pulsedeck` est le point d’entrée opérationnel normal.

## Services

```bash
systemctl status mosquitto --no-pager
systemctl status pulsedeck-hub --no-pager
```

Logs :

```bash
sudo journalctl -u mosquitto -n 100 --no-pager
sudo journalctl -u pulsedeck-hub -n 100 --no-pager -o cat
sudo journalctl -u pulsedeck-hub -f
```

## Contrôles MQTT

Availability du hub :

```bash
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 \
  -t pulsedeck/v1/system/availability -C 1
```

Weather :

```bash
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/availability -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/current -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/hourly -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/weather/daily -C 1
```

News :

```bash
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/news/availability -C 1
mosquitto_sub -h <PI_IPV4> -p 1883 -q 1 -t pulsedeck/v1/news/latest -C 1
```

## Endpoint de santé Admin

L’endpoint non authentifié reste volontairement minimal :

```bash
curl -fsS http://<PI_IPV4>:8080/api/health
```

La configuration des collectors et le statut détaillé nécessitent une session Admin authentifiée.

## Smoke test des mises à jour Web dev

Après le déploiement du handoff privilégié de mise à jour, valider le canal de développement de bout en bout avec deux commits immuables consécutifs :

1. partir du commit dev **N** et confirmer que PulseDeck Admin indique que la build est à jour ;
2. publier un commit dev ultérieur **N+1** sans créer de GitHub Release stable ;
3. dans PulseDeck Admin, lancer la vérification et confirmer que **N+1** est annoncé comme disponible ;
4. démarrer l’installation depuis PulseDeck Admin ;
5. confirmer la progression `queued -> running -> succeeded`, en tenant compte du redémarrage du hub ;
6. après le retour du hub, confirmer que le checker indique de nouveau la build dev à jour et que les métadonnées installées pointent sur le commit **N+1**.

Cette procédure est uniquement un smoke test du canal dev ; elle ne définit ni rollback ni cache de versions.

Pour la première mise à jour après déploiement du modal Web Admin, confirmer aussi que le bouton d’installation ouvre la confirmation avant la mise en file, affiche les commits actuel et cible, conserve le suivi visible pendant le redémarrage/reconnexion attendu du hub, puis termine sur un état réussi/à jour.

## Configuration runtime

```text
/etc/pulsedeck/pulsedeck.toml
/etc/pulsedeck/secrets/openweather_api_key
/etc/pulsedeck/secrets/newsapi_api_key
```

Pour les changements normaux, utiliser PulseDeck Admin plutôt qu’une édition manuelle.

## Comportement en erreur

Les derniers snapshots retained valides Weather et News sont conservés si le fournisseur distant échoue. Le topic `*/availability` correspondant porte l’état courant de la source et une raison non sensible. Les clés fournisseur ne sont jamais journalisées.
