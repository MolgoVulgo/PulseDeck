from pathlib import Path

import pytest

from pulsedeck_hub.config import load_config


def _write(tmp_path: Path, weather: str) -> Path:
    path = tmp_path / "pulsedeck.toml"
    path.write_text(
        """[mqtt]\nhost = \"192.168.0.250\"\n\n""" + weather,
        encoding="utf-8",
    )
    return path


def test_weather_disabled_does_not_require_coordinates(tmp_path: Path) -> None:
    cfg = load_config(_write(tmp_path, "[collectors.weather]\nenabled = false\n"))
    assert cfg.weather.enabled is False
    assert cfg.weather.current_interval == 600


def test_weather_enabled_loads_contract(tmp_path: Path) -> None:
    cfg = load_config(
        _write(
            tmp_path,
            """[collectors.weather]\nenabled = true\nprovider = \"openweather-onecall-4\"\nlatitude = 49.0\nlongitude = 6.0\nlocation_name = \"Maison\"\n""",
        )
    )
    assert cfg.weather.enabled is True
    assert cfg.weather.latitude == 49.0
    assert cfg.weather.longitude == 6.0
    assert cfg.weather.hourly_hours == 48
    assert cfg.weather.daily_days == 10


def test_weather_interval_below_provider_refresh_is_rejected(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        """[collectors.weather]\nenabled = true\nlatitude = 49.0\nlongitude = 6.0\ncurrent_interval = 300\n""",
    )
    with pytest.raises(ValueError, match="current_interval"):
        load_config(path)


def test_admin_configuration_loads(tmp_path: Path) -> None:
    cfg = load_config(
        _write(
            tmp_path,
            """[admin]\nenabled = true\nlisten = \"192.168.0.250\"\nport = 8080\n\n[collectors.weather]\nenabled = false\n""",
        )
    )
    assert cfg.admin.enabled is True
    assert cfg.admin.listen == "192.168.0.250"
    assert cfg.admin.port == 8080


def test_news_configuration_loads(tmp_path: Path) -> None:
    cfg = load_config(
        _write(
            tmp_path,
            """[collectors.weather]\nenabled = false\n\n[collectors.news]\nenabled = true\nprovider = \"gnews\"\nmode = \"top-headlines\"\ncategory = \"technology\"\nlang = \"fr\"\ncountry = \"fr\"\nmax_articles = 10\ninterval = 1800\n""",
        )
    )
    assert cfg.news.enabled is True
    assert cfg.news.provider == "gnews"
    assert cfg.news.mode == "top-headlines"
    assert cfg.news.category == "technology"
    assert cfg.news.interval == 1800


def test_news_interval_below_minimum_is_rejected(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        """[collectors.weather]\nenabled = false\n\n[collectors.news]\nenabled = false\ninterval = 60\n""",
    )
    with pytest.raises(ValueError, match="collectors.news.interval"):
        load_config(path)
