# Weather — OpenWeather One Call 4.0

> L’anglais fait référence : [`../WEATHER.md`](../WEATHER.md).

## Fournisseur

Weather V1 utilise OpenWeather One Call API 4.0 avec :

```text
/data/4.0/onecall/current
/data/4.0/onecall/timeline/1h
/data/4.0/onecall/timeline/1day
```

Le Raspberry Pi réalise les requêtes HTTPS distantes et la normalisation. L’ESP32 n’a besoin ni des identifiants OpenWeather ni d’une pile HTTP/TLS.

## Configuration

TOML runtime :

```text
/etc/pulsedeck/pulsedeck.toml
```

Secret :

```text
/etc/pulsedeck/secrets/openweather_api_key
```

La configuration normale se fait dans PulseDeck Admin. La clé est masquée après stockage.

Cadences V1 par défaut :

```text
current : 600 s   (10 min)
hourly  : 1800 s  (30 min)
daily   : 10800 s (3 h)
```

Horizon hourly : 48 heures. Horizon daily : 10 jours.

## Sécurité de pagination

La requête initiale `timeline/1h` / `timeline/1day` est envoyée sans `start`. PulseDeck suit les URL `next` du fournisseur. Une réponse live a déjà renvoyé des liens de pagination en `http://` ; PulseDeck n’accepte donc ces URL que pour l’hôte exact `api.openweathermap.org` et le chemin One Call 4.0, puis force HTTPS avant de les suivre. La clé API n’est jamais transmise en clair.

## MQTT

Tous les messages Weather V1 sont retained en QoS 1 :

```text
pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily
```

Les unités normalisées utilisent Celsius, hPa, pourcentage, m/s et millimètres lorsque pertinent. Les champs absents du fournisseur ne sont pas inventés.

## Erreurs

En cas d’échec fournisseur, les derniers snapshots retained current/hourly/daily valides sont conservés. `weather/availability` indique la source offline avec une raison non sensible. Une réussite `current` remet l’availability online.
