# News — GNews API v4

> L’anglais fait référence : [`../NEWS.md`](../NEWS.md).

## Contrat fournisseur

News V1 utilise **GNews API v4**. Les requêtes distantes sont exclusivement en HTTPS et l’authentification fournisseur est envoyée uniquement via l’en-tête HTTP :

```text
X-Api-Key: <secret>
```

PulseDeck ne place pas la clé GNews dans la query string. Le secret reste ainsi hors des URL de requête, des logs d’accès ordinaires et des données referrer.

Endpoints pris en charge :

```text
GET https://gnews.io/api/v4/top-headlines
GET https://gnews.io/api/v4/search
```

## Configuration

La configuration normale se fait depuis PulseDeck Admin. Une nouvelle clé fournie est testée auprès du fournisseur avant d’être enregistrée, même si le collector reste désactivé.

Exemple TOML runtime :

```toml
[collectors.news]
enabled = false
provider = "gnews"
mode = "top-headlines"
category = "general"
query = ""
lang = "fr"
country = "fr"
max_articles = 10
interval = 1800
request_timeout = 15
api_key_file = "/etc/pulsedeck/secrets/gnews_api_key"
```

Secret :

```text
/etc/pulsedeck/secrets/gnews_api_key
```

La cadence par défaut de 30 minutes est prudente pour une petite installation. Les quotas GNews et la valeur maximale autorisée de `max` dépendent du plan fournisseur. PulseDeck expose donc cadence et nombre d’articles dans Admin au lieu de supposer un quota payant.

## Modes

### `top-headlines`

Utilise les actualités courantes classées par le fournisseur. Catégories GNews disponibles :

```text
general, world, nation, business, technology,
entertainment, sports, science, health
```

Une requête optionnelle peut filtrer davantage `top-headlines`.

### `search`

Nécessite une requête. PulseDeck recherche dans titre/description et demande `sortby=publishedAt` pour que le snapshot retained représente les articles correspondants les plus récents.

Langue et pays sont des codes optionnels à deux lettres. Une valeur vide omet le filtre fournisseur correspondant.

## MQTT

News V1 publie des messages retained QoS 1 :

```text
pulsedeck/v1/news/availability
pulsedeck/v1/news/latest
```

`news/latest` utilise le schema 1 et contient un tableau `articles` normalisé. Chaque article utilisable peut contenir :

```text
id
title
description
url
image_url
published_ts
lang
source.id
source.name
source.url
source.country
```

Le champ fournisseur `content` n’est volontairement pas republié afin de garder le payload retained compact pour les consommateurs ESP32. `publishedAt` est normalisé en timestamp Unix `published_ts`.

## Erreurs

Si GNews échoue, PulseDeck conserve le dernier snapshot retained valide `news/latest` et publie `news/availability=offline` avec une raison non sensible. La clé API n’est jamais journalisée ni incluse dans les payloads MQTT.
