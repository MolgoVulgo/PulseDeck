# News — provider selection

> English is authoritative. French translation: [`fr/NEWS.md`](fr/NEWS.md).

## Overview

PulseDeck News V1 supports two interchangeable providers:

- **NewsAPI v2** (`newsapi.org`);
- **GNews v4** (`gnews.io`).

Both are called over HTTPS. PulseDeck authenticates both providers exclusively with the HTTP header:

```text
X-Api-Key: <secret>
```

Provider keys are never placed in request URLs, MQTT payloads or logs. The active provider is selected in PulseDeck Admin and persisted as `collectors.news.provider`.

The provider-specific secrets are stored independently:

```text
/etc/pulsedeck/secrets/newsapi_api_key
/etc/pulsedeck/secrets/gnews_api_key
```

Switching provider does not delete or overwrite the other provider's stored key.

## Common PulseDeck behavior

News publishes retained QoS 1 messages on:

```text
pulsedeck/v1/news/availability
pulsedeck/v1/news/latest
```

`news/latest` keeps schema 1 regardless of provider. PulseDeck normalizes the common display fields:

```text
title
author          # when supplied by the provider
description
url
image_url
published_ts
source.id
source.name
```

Long provider `content` is deliberately not republished. Provider totals are normalized to `total_results`. The payload `source` and `feed.provider` identify the active provider (`newsapi` or `gnews`).

PulseDeck fixes provider pagination to page 1 because `news/latest` is a current display snapshot rather than an archive browser. `max_articles`, `interval` and `request_timeout` remain PulseDeck runtime settings.

## NewsAPI v2

Endpoints:

```text
GET https://newsapi.org/v2/top-headlines
GET https://newsapi.org/v2/everything
```

### `top-headlines`

PulseDeck can send:

```text
q
sources
country
category
pageSize
page=1
```

`sources` cannot be combined with `country` or `category`. PulseDeck validates this rule and omits `country` / `category` while source IDs are selected.

Supported categories used by PulseDeck:

```text
business, entertainment, general, health,
science, sports, technology
```

### `everything`

PulseDeck can send:

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

`q` is optional in PulseDeck. `searchIn` is only sent when `q` is present. `sources` is limited to 20 source IDs. `sortBy` supports `publishedAt`, `relevancy` and `popularity`.

## GNews v4

Endpoints:

```text
GET https://gnews.io/api/v4/top-headlines
GET https://gnews.io/api/v4/search
```

PulseDeck uses `X-Api-Key` even though GNews also accepts an `apikey` query parameter, so the secret stays out of URLs.

For both GNews endpoints PulseDeck sends `max`, fixes `page=1`, and sends `truncate=content` because PulseDeck does not republish provider content.

### `top-headlines`

PulseDeck can send:

```text
category
lang
country
max
nullable
from
to
q
page=1
truncate=content
```

The nine GNews categories are:

```text
general, world, nation, business, technology,
entertainment, sports, science, health
```

`q` is optional and limited to 200 characters.

### `search`

`q` is mandatory and limited to 200 characters. PulseDeck can also send:

```text
lang
country
max
in
nullable
from
to
sortby
page=1
truncate=content
```

`in` supports `title`, `description` and `content`, including comma-separated combinations. `nullable` supports `description`, `content` and `image`. `sortby` supports `publishedAt` and `relevance`.

GNews language and country values are entered as two-letter codes and are provider-tested before save.

## Admin transaction model

A new key is tested against the selected provider before it is persisted. When News is enabled, saving configuration also requires a successful provider test. Only after validation does PulseDeck atomically update TOML / the selected provider key and hot-reload the collector.

If application fails after persistence, PulseDeck attempts to restore the previous configuration and the previous value of the selected provider secret.

## Failure behavior

If a provider request fails, PulseDeck preserves the last valid retained `news/latest` snapshot and publishes `news/availability=offline` with a sanitized reason. API keys are never included in errors, logs or MQTT messages.
