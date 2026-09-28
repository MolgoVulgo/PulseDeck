# News — sélection du fournisseur

> L’anglais fait référence : [`../NEWS.md`](../NEWS.md).

## Vue d’ensemble

News V1 prend en charge deux fournisseurs interchangeables :

- **NewsAPI v2** (`newsapi.org`) ;
- **GNews v4** (`gnews.io`).

Les deux sont interrogés en HTTPS. PulseDeck authentifie exclusivement les deux fournisseurs avec le header HTTP :

```text
X-Api-Key: <secret>
```

Les clés ne sont jamais placées dans les URL, les payloads MQTT ou les logs. Le fournisseur actif est choisi dans PulseDeck Admin et persisté dans `collectors.news.provider`.

Les secrets restent séparés :

```text
/etc/pulsedeck/secrets/newsapi_api_key
/etc/pulsedeck/secrets/gnews_api_key
```

Changer de fournisseur ne supprime ni n’écrase la clé de l’autre fournisseur.

## Comportement commun PulseDeck

News publie en retained QoS 1 sur :

```text
pulsedeck/v1/news/availability
pulsedeck/v1/news/latest
```

`news/latest` conserve le schema 1 quel que soit le fournisseur. PulseDeck normalise les champs utiles à l’affichage :

```text
title
author          # si fourni
description
url
image_url
published_ts
source.id
source.name
```

Le `content` long des fournisseurs n’est pas republié. Les totaux sont normalisés en `total_results`. `source` et `feed.provider` identifient le fournisseur actif (`newsapi` ou `gnews`).

PulseDeck fixe la pagination fournisseur à la page 1 car `news/latest` est un snapshot courant et non un navigateur d’archives. `max_articles`, `interval` et `request_timeout` restent des réglages runtime PulseDeck.

## NewsAPI v2

Endpoints :

```text
GET https://newsapi.org/v2/top-headlines
GET https://newsapi.org/v2/everything
```

### `top-headlines`

PulseDeck peut envoyer `q`, `sources`, `country`, `category`, `pageSize` et `page=1`. `sources` ne peut pas être combiné avec `country` ou `category` ; PulseDeck valide cette règle.

Catégories : `business`, `entertainment`, `general`, `health`, `science`, `sports`, `technology`.

### `everything`

PulseDeck peut envoyer `q`, `searchIn`, `sources`, `domains`, `excludeDomains`, `from`, `to`, `language`, `sortBy`, `pageSize` et `page=1`.

`q` reste optionnel dans PulseDeck. `searchIn` n’est envoyé que si `q` est renseigné. `sources` est limité à 20 IDs. `sortBy` accepte `publishedAt`, `relevancy` et `popularity`.

## GNews v4

Endpoints :

```text
GET https://gnews.io/api/v4/top-headlines
GET https://gnews.io/api/v4/search
```

PulseDeck utilise `X-Api-Key` même si GNews accepte aussi `apikey` dans la query string afin de garder le secret hors des URL.

Pour les deux endpoints GNews, PulseDeck envoie `max`, fixe `page=1` et envoie `truncate=content` puisque le contenu fournisseur n’est pas republié.

### `top-headlines`

PulseDeck peut envoyer `category`, `lang`, `country`, `max`, `nullable`, `from`, `to`, `q`, `page=1` et `truncate=content`.

Les neuf catégories GNews sont : `general`, `world`, `nation`, `business`, `technology`, `entertainment`, `sports`, `science`, `health`.

`q` est optionnel et limité à 200 caractères.

### `search`

`q` est obligatoire et limité à 200 caractères. PulseDeck peut aussi envoyer `lang`, `country`, `max`, `in`, `nullable`, `from`, `to`, `sortby`, `page=1` et `truncate=content`.

`in` accepte `title`, `description`, `content` et leurs combinaisons séparées par des virgules. `nullable` accepte `description`, `content` et `image`. `sortby` accepte `publishedAt` et `relevance`.

Les codes langue/pays GNews sont saisis sur deux lettres puis validés par un test fournisseur avant sauvegarde.

## Modèle transactionnel Admin

Une nouvelle clé est testée auprès du fournisseur sélectionné avant stockage. Quand News est activé, la sauvegarde impose également un test fournisseur réussi. PulseDeck met ensuite à jour atomiquement TOML / la clé du fournisseur sélectionné et recharge le collector à chaud.

En cas d’échec après persistance, PulseDeck tente de restaurer la configuration précédente et l’ancienne valeur du secret du fournisseur sélectionné.

## Erreurs

Si le fournisseur échoue, PulseDeck conserve le dernier snapshot retained valide `news/latest` et publie `news/availability=offline` avec une raison nettoyée. Les clés API ne sont jamais incluses dans les erreurs, logs ou messages MQTT.
