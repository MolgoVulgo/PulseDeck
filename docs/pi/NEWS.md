# News — NewsAPI v2

> English is authoritative. French translation: [`fr/NEWS.md`](fr/NEWS.md).

## Provider contract

News V1 uses **NewsAPI v2** from `newsapi.org`. Provider requests are HTTPS-only and PulseDeck sends the API key exclusively through the HTTP header:

```text
X-Api-Key: <secret>
```

PulseDeck never places the NewsAPI key in the query string.

Supported endpoints:

```text
GET https://newsapi.org/v2/top-headlines
GET https://newsapi.org/v2/everything
```

NewsAPI also accepts query-string and `Authorization` authentication, but PulseDeck intentionally uses only `X-Api-Key` so the key stays out of request URLs.

## Configuration

Normal configuration is performed through PulseDeck Admin. A newly supplied key is provider-tested before it is persisted, even when the collector remains disabled.

Runtime TOML example:

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

Secret path:

```text
/etc/pulsedeck/secrets/newsapi_api_key
```

The default cadence is 30 minutes. Provider quotas depend on the NewsAPI plan, so PulseDeck exposes cadence and snapshot size in Admin instead of assuming a specific quota.

## Modes

### `top-headlines`

Uses `/v2/top-headlines`. PulseDeck can send:

```text
country
category
q
pageSize
page=1
```

Supported categories in the provider contract are:

```text
business, entertainment, general, health,
science, sports, technology
```

`q` is optional. `country` is an optional two-letter country code. PulseDeck does not send a language parameter in this mode because NewsAPI does not define one for `/v2/top-headlines`.

### `everything`

Uses `/v2/everything` and requires `q`. PulseDeck sends:

```text
q
language
sortBy=publishedAt
pageSize
page=1
```

The query is limited to 500 characters by the provider contract. `language` is an optional two-letter language code. `country` and `category` are not sent in this mode.

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

The payload also contains a `feed` object describing the selected mode and relevant filters, plus `total_results` when the provider returns it.

## Failure behavior

If NewsAPI fails, PulseDeck keeps the last good retained `news/latest` snapshot and publishes `news/availability=offline` with a sanitized reason. The API key is never logged or included in MQTT payloads.
