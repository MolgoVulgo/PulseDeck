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
            """[collectors.weather]\nenabled = false\n\n[collectors.news]\nenabled = true\nprovider = \"newsapi\"\nmode = \"top-headlines\"\ncategory = \"technology\"\nlang = \"fr\"\ncountry = \"fr\"\nmax_articles = 10\ninterval = 1800\n""",
        )
    )
    assert cfg.news.enabled is True
    assert cfg.news.provider == "newsapi"
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



def test_gnews_configuration_loads_with_separate_secret(tmp_path: Path) -> None:
    cfg = load_config(
        _write(
            tmp_path,
            """[collectors.weather]\nenabled = false\n\n[collectors.news]\nenabled = false\nprovider = \"gnews\"\nmode = \"search\"\nquery = \"OpenAI\"\ncategory = \"world\"\nlang = \"fr\"\ncountry = \"fr\"\nnullable = \"description,image\"\nsort_by = \"relevance\"\n""",
        )
    )
    assert cfg.news.provider == "gnews"
    assert cfg.news.mode == "search"
    assert cfg.news.api_key_file.name == "gnews_api_key"
    assert cfg.news.nullable == "description,image"


def test_machines_load_multiple_configurable_targets(tmp_path: Path) -> None:
    cfg = load_config(
        _write(
            tmp_path,
            """[collectors.weather]\nenabled = false\n\n[collectors.machines]\nenabled = true\npoll_interval = 3\n\n[[collectors.machines.devices]]\nid = \"mini-server\"\nname = \"Mini serveur\"\ntype = \"server\"\nhost = \"192.168.0.1\"\nport = 8765\n\n[[collectors.machines.devices]]\nid = \"gaming-pc\"\nname = \"PC gamer\"\ntype = \"pc\"\nhost = \"gaming.local\"\nport = 9000\n""",
        )
    )
    assert cfg.machines.enabled is True
    assert cfg.machines.poll_interval == 3
    assert [device.id for device in cfg.machines.devices] == ["mini-server", "gaming-pc"]
    assert cfg.machines.devices[0].host == "192.168.0.1"
    assert cfg.machines.devices[0].machine_type == "server"
    assert cfg.machines.devices[1].machine_type == "pc"
    assert cfg.machines.devices[1].host == "gaming.local"
    assert cfg.machines.devices[1].port == 9000


def test_enabled_machines_requires_one_enabled_device(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        """[collectors.weather]\nenabled = false\n\n[collectors.machines]\nenabled = true\n""",
    )
    with pytest.raises(ValueError, match="at least one enabled device"):
        load_config(path)


def test_machine_host_rejects_url_syntax(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        """[collectors.weather]
enabled = false

[collectors.machines]
enabled = true

[[collectors.machines.devices]]
id = "mini-server"
name = "Mini serveur"
host = "http://192.168.0.1"
""",
    )
    with pytest.raises(ValueError, match="IP address or hostname"):
        load_config(path)


def test_patch21_mini_server_config_migrates_in_memory(tmp_path: Path) -> None:
    cfg = load_config(
        _write(
            tmp_path,
            """[collectors.weather]\nenabled = false\n\n[collectors.mini_server]\nenabled = true\nhost = \"10.0.0.42\"\nport = 9999\n""",
        )
    )
    assert cfg.machines.enabled is True
    assert len(cfg.machines.devices) == 1
    device = cfg.machines.devices[0]
    assert device.id == "mini-server"
    assert device.machine_type == "server"
    assert device.host == "10.0.0.42"
    assert device.port == 9999


def test_machine_type_is_validated(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        """[collectors.weather]
enabled = false

[collectors.machines]
enabled = true

[[collectors.machines.devices]]
id = "host-a"
name = "Host A"
type = "router"
host = "host-a.local"
""",
    )
    with pytest.raises(ValueError, match="type must be"):
        load_config(path)
