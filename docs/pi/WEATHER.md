# Weather — OpenWeather One Call 4.0

## Fournisseur V1

Le premier collector applicatif de PulseDeck utilise **OpenWeather One Call API 4.0**.

Documentation fournisseur :

```text
https://openweathermap.org/api/one-call-4
```

Le hub utilise uniquement les endpoints nécessaires au contrat MQTT V1 :

```text
/data/4.0/onecall/current
/data/4.0/onecall/timeline/1h
/data/4.0/onecall/timeline/1day
```

Les timelines `1min` et `15min` ne sont pas consommées dans `patch_0007`. Elles restent disponibles pour une future vue précipitations/nowcast.

## Configuration

La configuration applicative se trouve dans :

```text
/etc/pulsedeck/pulsedeck.toml
```

Exemple :

```toml
[collectors.weather]
enabled = true
provider = "openweather-onecall-4"
latitude = 49.0
longitude = 6.0
location_name = "Maison"
api_key_file = "/etc/pulsedeck/secrets/openweather_api_key"
lang = "fr"
current_interval = 600
hourly_interval = 1800
daily_interval = 10800
hourly_hours = 48
daily_days = 10
request_timeout = 15
```

La clé API ne doit pas être placée dans le TOML. Elle est stockée séparément :

```text
/etc/pulsedeck/secrets/openweather_api_key
```

Le déployeur place ce fichier avec un accès limité à `root` et au groupe `pulsedeck`.

## Configuration via PulseDeck Admin

À partir de `patch_0008`, `setup_pi.sh` et `deploy_hub.sh` n’interrogent plus l’utilisateur sur la clé ou le lieu. Ils installent le socle, activent PulseDeck Admin et conservent une configuration Weather existante.

Une nouvelle installation configure Weather dans l’interface Web :

1. saisir ou remplacer la clé OpenWeather ;
2. rechercher le lieu via le Geocoding API ou utiliser des coordonnées ;
3. tester l’accès One Call 4.0 ;
4. enregistrer et activer le collector.

Le test fournisseur est exécuté avant l’écriture. En cas d’échec d’application, la configuration précédente est restaurée. La clé API n’est jamais renvoyée en clair par l’API Web.

## Cadences V1

```text
current : 600 s   / 10 min
hourly  : 1800 s  / 30 min
daily   : 10800 s / 3 h
```

L'horaire récupère jusqu'à 48 heures. Comme One Call 4.0 limite la timeline `1h` à 20 enregistrements par réponse, le collector suit les liens de pagination `next` jusqu'à obtenir les 48 enregistrements ou atteindre la fin du jeu de données.

Les requêtes initiales `timeline/1h` et `timeline/1day` sont envoyées sans paramètre `start`. Pour avancer dans la timeline, le collector utilise exclusivement les URLs `next` préparées par OpenWeather. La documentation fournisseur les montre en HTTPS ; un retour live sur `bluebox` a toutefois observé des liens `next` en HTTP. À partir de `patch_0007-2`, PulseDeck n'accepte ces liens que pour l'hôte exact `api.openweathermap.org` et le chemin One Call 4.0, puis force HTTPS avant toute requête afin que la clé API ne soit jamais transmise en clair.

Le daily récupère jusqu'à 10 jours, ce qui tient dans la limite de 10 enregistrements d'une réponse `1day`.

## MQTT

Tous les messages Weather V1 sont retained avec QoS 1 :

```text
pulsedeck/v1/weather/availability
pulsedeck/v1/weather/current
pulsedeck/v1/weather/hourly
pulsedeck/v1/weather/daily
```

En cas d'échec fournisseur, les derniers payloads météo valides ne sont pas effacés. Seul `weather/availability` passe offline. L'ESP32 peut donc continuer à afficher les dernières données avec sa propre logique `fresh/stale/offline`.

## Payload `weather/availability`

```json
{
  "schema": 1,
  "source": "openweather-onecall-4",
  "state": "online",
  "ts": 1790530000,
  "last_success": 1790530000
}
```

En cas d'erreur, `state` vaut `offline` et un champ `reason` non sensible peut être présent.

## Payload `weather/current`

Le payload est normalisé en unités métriques :

```json
{
  "schema": 1,
  "source": "openweather-onecall-4",
  "ts": 1790530000,
  "source_ts": 1790529900,
  "location": {
    "name": "Maison",
    "lat": 49.0,
    "lon": 6.0,
    "timezone": "Europe/Paris",
    "timezone_offset": 7200
  },
  "data": {
    "temperature_c": 18.6,
    "feels_like_c": 18.1,
    "pressure_hpa": 1017,
    "humidity_pct": 72,
    "wind_mps": 3.2,
    "condition": {
      "id": 802,
      "main": "Clouds",
      "description": "nuageux",
      "icon": "03d"
    }
  },
  "alert_ids": []
}
```

Les champs absents de la réponse fournisseur ne sont pas inventés.

## Payloads hourly/daily

`weather/hourly` contient un tableau `hours` d'au plus 48 éléments. Chaque élément porte son propre `ts`, les températures disponibles, pression, humidité, vent, probabilité de précipitation normalisée en `%`, précipitations et condition météo.

`weather/daily` contient un tableau `days` d'au plus 10 éléments avec notamment températures min/max et par période, lever/coucher du soleil, lune, pression, humidité, vent, UV, probabilité de précipitation et condition météo lorsque ces valeurs sont fournies.

## Erreurs et reprise

Le collector :

- n'effectue pas d'appel OpenWeather tant que MQTT n'est pas connecté ;
- conserve les derniers messages Weather retained lors d'une erreur HTTP/réseau ;
- republie `weather/availability=online` après une récupération current réussie ;
- utilise un délai court de reprise après erreur sans descendre sous la cadence nominale de 10 minutes en fonctionnement normal ;
- ne journalise jamais la clé API ni les URLs de pagination contenant cette clé.
