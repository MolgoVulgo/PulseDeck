# News — NewsAPI v2

> L’anglais fait référence : [`../NEWS.md`](../NEWS.md).

## Contrat fournisseur

News V1 utilise **NewsAPI v2** via `newsapi.org`. Les requêtes fournisseur utilisent uniquement HTTPS et PulseDeck envoie la clé API exclusivement dans l’en-tête HTTP :

```text
X-Api-Key: <secret>
```

PulseDeck ne place jamais la clé NewsAPI dans la query string.

Endpoints pris en charge :

```text
GET https://newsapi.org/v2/top-headlines
GET https://newsapi.org/v2/everything
```

NewsAPI accepte aussi l’authentification par query string et `Authorization`, mais PulseDeck utilise volontairement uniquement `X-Api-Key` afin de garder la clé hors des URL de requête.

## Configuration

La configuration normale se fait depuis PulseDeck Admin. Une nouvelle clé est testée auprès du fournisseur avant d’être enregistrée, même lorsque le collector reste désactivé.

Exemple TOML runtime :

```toml
[collectors.news]
enabled = false
provider = "newsapi"
mode = "top-headlines"
category = "general"
query = ""
lang = "fr"
country = "fr"
max_articles = 10
interval = 1800
request_timeout = 15
api_key_file = "/etc/pulsedeck/secrets/newsapi_api_key"
```

Secret :

```text
/etc/pulsedeck/secrets/newsapi_api_key
```

La cadence par défaut est de 30 minutes. Les quotas dépendent du plan NewsAPI ; PulseDeck expose donc la cadence et la taille du snapshot dans Admin sans supposer un quota particulier.

## Modes

### `top-headlines`

Utilise `/v2/top-headlines`. PulseDeck peut envoyer :

```text
country
category
q
pageSize
page=1
```

Catégories définies par le fournisseur :

```text
business, entertainment, general, health,
science, sports, technology
```

`q` est optionnel. `country` est un code pays optionnel sur deux lettres. PulseDeck n’envoie pas de paramètre de langue dans ce mode car NewsAPI n’en définit pas pour `/v2/top-headlines`.

### `everything`

Utilise `/v2/everything` et nécessite `q`. PulseDeck envoie :

```text
q
language
sortBy=publishedAt
pageSize
page=1
```

La requête est limitée à 500 caractères par le contrat fournisseur. `language` est un code langue optionnel sur deux lettres. `country` et `category` ne sont pas envoyés dans ce mode.

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

Le payload contient également un objet `feed` décrivant le mode et les filtres pertinents, ainsi que `total_results` lorsque le fournisseur le renvoie.

## Erreurs

Si NewsAPI échoue, PulseDeck conserve le dernier snapshot retained valide `news/latest` et publie `news/availability=offline` avec une raison non sensible. La clé API n’est jamais journalisée ni incluse dans les payloads MQTT.
