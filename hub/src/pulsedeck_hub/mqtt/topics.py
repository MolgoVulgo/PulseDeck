"""PulseDeck MQTT topic constants fixed by the V1 namespace contract."""

ROOT = "pulsedeck/v1"
SYSTEM_AVAILABILITY = f"{ROOT}/system/availability"

WEATHER_AVAILABILITY = f"{ROOT}/weather/availability"
WEATHER_CURRENT = f"{ROOT}/weather/current"
WEATHER_HOURLY = f"{ROOT}/weather/hourly"
WEATHER_DAILY = f"{ROOT}/weather/daily"

NEWS_AVAILABILITY = f"{ROOT}/news/availability"
NEWS_LATEST = f"{ROOT}/news/latest"

PC_GAMER_AVAILABILITY = f"{ROOT}/pc/gamer/availability"
PC_GAMER_DASHBOARD = f"{ROOT}/pc/gamer/dashboard"

MINI_SERVER_AVAILABILITY = f"{ROOT}/server/mini/availability"
MINI_SERVER_DASHBOARD = f"{ROOT}/server/mini/dashboard"

PRINTER_AVAILABILITY = f"{ROOT}/printer/availability"
PRINTER_STATUS = f"{ROOT}/printer/status"
PRINTER_JOB = f"{ROOT}/printer/job"
PRINTER_THUMBNAIL = f"{ROOT}/printer/thumbnail"
