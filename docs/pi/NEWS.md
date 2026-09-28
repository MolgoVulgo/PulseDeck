# News — NewsAPI v2

> English is authoritative. French translation: [`fr/NEWS.md`](fr/NEWS.md).

## Provider contract

News V1 uses **NewsAPI v2** from `newsapi.org`. Provider requests are HTTPS-only. PulseDeck sends the API key exclusively in the HTTP header:

```text
X-Api-Key: <secret>
```

The key is never placed in the query string. PulseDeck uses these provider endpoints:

```text
GET https://newsapi.org/v2/top-headlines
GET https://newsapi.org/v2/everything
```

NewsAPI also accepts query-string and `Authorization` authentication, but PulseDeck intentionally uses only `X-Api-Key` so the secret stays out of request URLs.

## Configuration

Normal configuration is performed through PulseDeck Admin. A newly supplied key is provider-tested before it is persisted, even when the collector remains disabled.

Runtime TOML example:

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

Secret path:

```text
/etc/pulsedeck/secrets/newsapi_api_key
```

`interval` and `request_timeout` are PulseDeck runtime settings, not NewsAPI request parameters. `max_articles` maps to NewsAPI `pageSize`. PulseDeck deliberately keeps `page=1` because `news/latest` is a current display snapshot rather than a historical browser.

## `top-headlines`

PulseDeck supports the documented `/v2/top-headlines` request parameters relevant to the current snapshot:

```text
q
sources
country
category
pageSize
page=1
```

`q` is optional. `sources` is a comma-separated list of NewsAPI source identifiers. NewsAPI does **not** allow `sources` to be combined with `country` or `category`; PulseDeck validates this rule and the Admin UI automatically omits `country` and `category` while source IDs are selected.

Supported categories are:

```text
business, entertainment, general, health,
science, sports, technology
```

`country` is restricted to the country codes currently documented by NewsAPI. `/v2/top-headlines` has no `language` parameter, so PulseDeck does not send one in this mode.

## `everything`

PulseDeck supports the documented `/v2/everything` filters:

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

`q` accepts NewsAPI advanced search syntax and is limited to 500 characters. `searchIn` can restrict a query to `title`, `description` and/or `content`; PulseDeck omits `searchIn` when `q` is empty.

`sources` accepts up to 20 comma-separated source IDs. `domains` and `excludeDomains` are comma-separated domain lists. `from` and `to` accept ISO 8601 date/date-time values. Leaving them empty is recommended for a continuously live dashboard; setting fixed values intentionally freezes the provider time window.

`language` is restricted to NewsAPI's documented language codes. `sortBy` supports:

```text
relevancy
popularity
publishedAt
```

The default is `publishedAt`. `country` and `category` are not sent to `/v2/everything`.

## MQTT

News V1 publishes retained QoS 1 messages:

```text
pulsedeck/v1/news/availability
pulsedeck/v1/news/latest
```

`news/latest` uses schema 1 and contains a normalized `articles` array. Each usable article may include:

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

NewsAPI `content` is deliberately not republished. `publishedAt` is normalized to Unix `published_ts`.

The payload also contains a `feed` object describing the active mode and relevant filters, plus `total_results` when the provider returns it.

## Failure behavior

If NewsAPI fails, PulseDeck keeps the last good retained `news/latest` snapshot and publishes `news/availability=offline` with a sanitized reason. The API key is never logged or included in MQTT payloads.
