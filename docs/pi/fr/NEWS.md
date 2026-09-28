# News — NewsAPI v2

> L’anglais fait référence : [`../NEWS.md`](../NEWS.md).

## Contrat fournisseur

News V1 utilise **NewsAPI v2** via `newsapi.org`. Les requêtes fournisseur utilisent uniquement HTTPS. PulseDeck envoie la clé API exclusivement dans l’en-tête HTTP :

```text
X-Api-Key: <secret>
```

La clé n’est jamais placée dans la query string. PulseDeck utilise les endpoints fournisseur suivants :

```text
GET https://newsapi.org/v2/top-headlines
GET https://newsapi.org/v2/everything
```

NewsAPI accepte aussi l’authentification par query string et `Authorization`, mais PulseDeck utilise volontairement uniquement `X-Api-Key` afin de garder le secret hors des URL.

## Configuration

La configuration normale se fait depuis PulseDeck Admin. Une nouvelle clé est testée auprès du fournisseur avant d’être enregistrée, même lorsque le collector reste désactivé.

Exemple TOML runtime :

```toml
[collectors.news]
enabled = false
provider = "newsapi"
mode = "top-headlines"
query = ""
sources = ""
country = "fr"
category = ""
search_in = ""
domains = ""
exclude_domains = ""
from = ""
to = ""
lang = "fr"
sort_by = "publishedAt"
max_articles = 10
interval = 1800
request_timeout = 15
api_key_file = "/etc/pulsedeck/secrets/newsapi_api_key"
```

Secret :

```text
/etc/pulsedeck/secrets/newsapi_api_key
```

`interval` et `request_timeout` sont des paramètres runtime PulseDeck, pas des paramètres NewsAPI. `max_articles` correspond à `pageSize`. PulseDeck conserve volontairement `page=1` car `news/latest` est un snapshot courant destiné à l’affichage, pas un navigateur d’archives.

## `top-headlines`

PulseDeck prend en charge les paramètres documentés de `/v2/top-headlines` utiles au snapshot courant :

```text
q
sources
country
category
pageSize
page=1
```

`q` est optionnel. `sources` contient une liste d’identifiants de sources NewsAPI séparés par des virgules. NewsAPI interdit de combiner `sources` avec `country` ou `category` ; PulseDeck valide cette règle et l’Admin omet automatiquement `country` et `category` lorsqu’une ou plusieurs sources sont renseignées.

Catégories prises en charge :

```text
business, entertainment, general, health,
science, sports, technology
```

`country` est limité aux codes pays actuellement documentés par NewsAPI. `/v2/top-headlines` ne possède pas de paramètre `language`, donc PulseDeck n’en envoie pas dans ce mode.

## `everything`

PulseDeck prend en charge les filtres documentés de `/v2/everything` :

```text
q
searchIn
sources
domains
excludeDomains
from
to
language
sortBy
pageSize
page=1
```

`q` accepte la syntaxe de recherche avancée NewsAPI et est limité à 500 caractères. `searchIn` peut limiter la recherche à `title`, `description` et/ou `content`; PulseDeck omet `searchIn` quand `q` est vide.

`sources` accepte jusqu’à 20 identifiants séparés par des virgules. `domains` et `excludeDomains` sont des listes de domaines séparées par des virgules. `from` et `to` acceptent des dates/date-heures ISO 8601. Pour un dashboard live, il est recommandé de les laisser vides ; des valeurs fixes figent volontairement la fenêtre temporelle fournisseur.

`language` est limité aux codes actuellement documentés par NewsAPI. `sortBy` accepte :

```text
relevancy
popularity
publishedAt
```

La valeur par défaut est `publishedAt`. `country` et `category` ne sont pas envoyés à `/v2/everything`.

## MQTT

News V1 publie des messages retained QoS 1 :

```text
pulsedeck/v1/news/availability
pulsedeck/v1/news/latest
```

`news/latest` utilise le schema 1 et contient un tableau `articles` normalisé. Chaque article utilisable peut contenir :

```text
title
author
description
url
image_url
published_ts
source.id
source.name
```

Le champ NewsAPI `content` n’est volontairement pas republié. `publishedAt` est normalisé en timestamp Unix `published_ts`.

Le payload contient aussi un objet `feed` décrivant le mode actif et les filtres pertinents, ainsi que `total_results` lorsque le fournisseur le renvoie.

## Erreurs

Si NewsAPI échoue, PulseDeck conserve le dernier snapshot retained valide `news/latest` et publie `news/availability=offline` avec une raison non sensible. La clé API n’est jamais journalisée ni incluse dans les payloads MQTT.
