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
