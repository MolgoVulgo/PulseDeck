# News — GNews API v4

> English is authoritative. French translation: [`fr/NEWS.md`](fr/NEWS.md).

## Provider contract

News V1 uses **GNews API v4**. Remote requests are HTTPS-only and provider authentication is sent exclusively through the HTTP header:

```text
X-Api-Key: <secret>
```

PulseDeck does not put the GNews key in the query string. This keeps the secret out of request URLs, ordinary access logs and referrer data.

Provider endpoints supported by PulseDeck:

```text
GET https://gnews.io/api/v4/top-headlines
GET https://gnews.io/api/v4/search
```

## Configuration

Normal configuration is performed through PulseDeck Admin. A newly supplied key is provider-tested before it is persisted, even while the collector remains disabled.

Runtime TOML example:

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

Secret path:

```text
/etc/pulsedeck/secrets/gnews_api_key
```

The default 30-minute cadence is conservative for small deployments. GNews quotas and the maximum allowed `max` value depend on the provider plan. PulseDeck exposes the cadence and article count in Admin instead of assuming a paid quota.

## Modes

### `top-headlines`

Uses the provider's ranked current headlines. Supported GNews categories are:

```text
general, world, nation, business, technology,
entertainment, sports, science, health
```

An optional query can further filter the top-headlines request.

### `search`

Requires a query. PulseDeck searches title/description and requests `sortby=publishedAt` so the retained snapshot represents the latest matching stories.

Language and country are optional two-letter codes. Empty values omit the corresponding provider filter.

## MQTT

News V1 publishes retained QoS 1 messages:

```text
pulsedeck/v1/news/availability
pulsedeck/v1/news/latest
```

`news/latest` uses schema 1 and contains a normalized `articles` array. Each usable article may include:

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

Provider `content` is deliberately not republished to keep the retained payload compact for ESP32 consumers. `publishedAt` is normalized to Unix `published_ts`.

## Failure behavior

If GNews fails, PulseDeck keeps the last good retained `news/latest` snapshot and publishes `news/availability=offline` with a sanitized reason. The API key is never logged or included in MQTT payloads.
