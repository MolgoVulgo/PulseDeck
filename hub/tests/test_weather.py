from pathlib import Path

import pytest

from pulsedeck_hub.collectors.weather import (
    OpenWeatherClient,
    WeatherError,
    WeatherResponse,
    normalize_current,
    normalize_daily,
    normalize_hourly,
)
from pulsedeck_hub.config import WeatherConfig


def response(data):
    return WeatherResponse(data, 49.1, 6.2, "Europe/Paris", 7200)


def test_current_normalization():
    payload = normalize_current(response([{
        "dt": 100,
        "temp": 18.5,
        "feels_like": 18.0,
        "pressure": 1017,
        "humidity": 72,
        "wind_speed": 3.2,
        "rain": {"1h": 0.4},
        "weather": [{"id": 500, "main": "Rain", "description": "pluie", "icon": "10d"}],
        "alerts": ["abc"],
    }]), "Maison")
    assert payload["source_ts"] == 100
    assert payload["data"]["temperature_c"] == 18.5
    assert payload["data"]["rain_1h_mm"] == 0.4
    assert payload["alert_ids"] == ["abc"]


def test_hourly_pop_is_percent():
    payload = normalize_hourly(response([{"dt": 100, "temp": 10.0, "pop": 0.42}]), "Maison", 48)
    assert payload["hours"][0]["pop_pct"] == 42


def test_daily_temperature_fields():
    payload = normalize_daily(response([{"dt": 100, "temp": {"min": 4.0, "max": 12.0}, "pop": 0.1}]), "Maison", 10)
    day = payload["days"][0]
    assert day["temperature_min_c"] == 4.0
    assert day["temperature_max_c"] == 12.0
    assert day["pop_pct"] == 10


def test_timeline_initial_request_omits_start(monkeypatch):
    cfg = WeatherConfig(enabled=True, latitude=49.0, longitude=6.0, api_key_file=Path("/unused"))
    client = OpenWeatherClient(cfg)
    calls = []

    def fake_request(path_or_url, **kwargs):
        calls.append((path_or_url, kwargs))
        return WeatherResponse(
            [{"dt": 1000}],
            49.0,
            6.0,
            "Europe/Paris",
            7200,
            None,
        )

    monkeypatch.setattr("pulsedeck_hub.collectors.weather.time.time", lambda: 1000)
    monkeypatch.setattr(client, "_request", fake_request)
    result = client.timeline("1h", 1)

    assert len(result.data) == 1
    assert calls == [("timeline/1h", {})]


def test_pagination_collects_multiple_hourly_pages(monkeypatch):
    cfg = WeatherConfig(enabled=True, latitude=49.0, longitude=6.0, api_key_file=Path("/unused"))
    client = OpenWeatherClient(cfg)
    pages = [
        WeatherResponse(
            [{"dt": 1000 + i * 3600} for i in range(20)],
            49.0,
            6.0,
            "Europe/Paris",
            7200,
            "https://api.openweathermap.org/page2",
        ),
        WeatherResponse(
            [{"dt": 1000 + i * 3600} for i in range(20, 40)],
            49.0,
            6.0,
            "Europe/Paris",
            7200,
            "https://api.openweathermap.org/page3",
        ),
        WeatherResponse(
            [{"dt": 1000 + i * 3600} for i in range(40, 50)],
            49.0,
            6.0,
            "Europe/Paris",
            7200,
            None,
        ),
    ]

    monkeypatch.setattr("pulsedeck_hub.collectors.weather.time.time", lambda: 1000)
    monkeypatch.setattr(client, "_request", lambda *args, **kwargs: pages.pop(0))
    result = client.timeline("1h", 48)
    assert len(result.data) == 48
    assert result.data[-1]["dt"] == 1000 + 47 * 3600



def test_http_pagination_url_is_upgraded_to_https(monkeypatch):
    cfg = WeatherConfig(enabled=True, latitude=49.0, longitude=6.0, api_key_file=Path("/unused"))
    client = OpenWeatherClient(cfg)
    seen = []

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return (
                b'{"lat":49.3615,"lon":6.1919,"timezone":"Europe/Paris",'
                b'"timezone_offset":7200,"data":[]}'
            )

    def fake_urlopen(request, timeout):
        seen.append((request.full_url, timeout))
        return FakeResponse()

    monkeypatch.setattr("pulsedeck_hub.collectors.weather.urlopen", fake_urlopen)
    live_next = (
        "http://api.openweathermap.org/data/4.0/onecall/timeline/1h"
        "?cnt=20&lat=49.3615&lon=6.1919&start=1790607600"
        "&appid=secret&units=metric&lang=fr"
    )

    client._request(live_next)

    assert len(seen) == 1
    assert seen[0][0].startswith(
        "https://api.openweathermap.org/data/4.0/onecall/timeline/1h?"
    )
    assert "appid=secret" in seen[0][0]
    assert not seen[0][0].startswith("http://")


def test_pagination_url_outside_onecall_path_is_rejected():
    cfg = WeatherConfig(enabled=True, latitude=49.0, longitude=6.0, api_key_file=Path("/unused"))
    client = OpenWeatherClient(cfg)
    with pytest.raises(WeatherError, match="unsafe pagination URL"):
        client._request("http://api.openweathermap.org/geo/1.0/direct?appid=secret")

def test_unsafe_pagination_host_is_rejected():
    cfg = WeatherConfig(enabled=True, latitude=49.0, longitude=6.0, api_key_file=Path("/unused"))
    client = OpenWeatherClient(cfg)
    with pytest.raises(WeatherError, match="unsafe pagination URL"):
        client._request("https://example.com/data/4.0/onecall/timeline/1h")
