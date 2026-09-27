# Weather — OpenWeather One Call 4.0

> English is authoritative. French translation: [`fr/WEATHER.md`](fr/WEATHER.md).

## Provider

Weather V1 uses OpenWeather One Call API 4.0 with:

```text
/data/4.0/onecall/current
/data/4.0/onecall/timeline/1h
/data/4.0/onecall/timeline/1day
```

The Raspberry Pi performs remote HTTPS requests and normalization. The ESP32 never needs OpenWeather credentials or HTTP/TLS logic.

## Configuration

Runtime TOML:

```text
/etc/pulsedeck/pulsedeck.toml
```

Secret:

```text
/etc/pulsedeck/secrets/openweather_api_key
```

Normal configuration is performed from PulseDeck Admin. The key is masked after storage.

Default V1 cadence:

```text
current : 600 s   (10 min)
hourly  : 1800 s  (30 min)
daily   : 10800 s (3 h)
```

Hourly horizon is 48 hours; daily horizon is 10 days.

## Pagination safety

The initial `timeline/1h` / `timeline/1day` request is sent without `start`. PulseDeck follows the provider `next` URLs. A live provider response has been observed returning `http://` pagination links, so PulseDeck accepts pagination only for the exact `api.openweathermap.org` host and One Call 4.0 path, then forces HTTPS before following the URL. The API key is never sent in clear text.

## MQTT

All Weather V1 messages are retained with QoS 1:

```text
pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily
```

Normalized units use Celsius, hPa, percent, m/s and millimetres where applicable. Missing provider fields are not invented.

## Failure behavior

On provider failure, last good current/hourly/daily retained snapshots remain available. `weather/availability` reports the source offline with a sanitized reason. A successful current request brings availability back online.
