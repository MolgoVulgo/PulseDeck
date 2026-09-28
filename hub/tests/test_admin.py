from pathlib import Path

from pulsedeck_hub.admin.catalog import build_service_catalog
from pulsedeck_hub.admin.ui import ADMIN_HTML
from pulsedeck_hub.admin.security import hash_password, make_session, verify_password, verify_session
from pulsedeck_hub.admin.storage import render_news_section, render_weather_section, update_news_config, update_secret, update_weather_config
from pulsedeck_hub.config import NewsConfig, WeatherConfig, load_config


def base_config(path: Path) -> None:
    path.write_text(
        """[mqtt]\nhost = \"192.168.0.250\"\n\n[admin]\nenabled = true\nlisten = \"192.168.0.250\"\nport = 8080\n\n[collectors.weather]\nenabled = false\nlocation_name = \"\"\n\n[collectors.news]\nenabled = false\n""",
        encoding="utf-8",
    )


def test_password_hash_and_session_round_trip() -> None:
    encoded = hash_password("correct horse battery staple")
    assert verify_password("correct horse battery staple", encoded)
    assert not verify_password("wrong password", encoded)
    secret = b"x" * 32
    token = make_session(secret, now=100, ttl=60)
    assert verify_session(token, secret, now=150)
    assert not verify_session(token, secret, now=161)


def test_weather_section_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "pulsedeck.toml"
    base_config(path)
    config = WeatherConfig(
        enabled=True,
        latitude=49.3615,
        longitude=6.1919,
        location_name="Yutz, Grand Est, FR",
        api_key_file=tmp_path / "openweather_api_key",
    )
    update_weather_config(path, config)
    loaded = load_config(path)
    assert loaded.weather.enabled is True
    assert loaded.weather.latitude == 49.3615
    assert loaded.weather.longitude == 6.1919
    assert loaded.weather.location_name == "Yutz, Grand Est, FR"
    assert "[collectors.news]" in path.read_text(encoding="utf-8")


def test_secret_write_is_not_logged_or_embedded(tmp_path: Path) -> None:
    secret_path = tmp_path / "secret"
    update_secret(secret_path, "abc-123")
    assert secret_path.read_text(encoding="utf-8") == "abc-123\n"
    assert secret_path.stat().st_mode & 0o777 == 0o660


def test_render_disabled_weather_omits_missing_coordinates() -> None:
    text = render_weather_section(WeatherConfig(enabled=False))
    assert "enabled = false" in text
    assert "latitude" not in text
    assert "longitude" not in text


def test_service_catalog_preserves_confirmed_future_contracts() -> None:
    catalog = build_service_catalog({"state": "online"}, True, {"state": "disabled"}, False)
    by_id = {item["id"]: item for item in catalog}
    assert by_id["weather"]["available"] is True
    assert by_id["weather"]["state"] == "online"
    assert by_id["news"]["available"] is True
    assert by_id["news"]["view"] == "news"
    assert by_id["news"]["provider"] == "NewsAPI"
    gnews_catalog = build_service_catalog({"state": "online"}, True, {"state": "online"}, True, "gnews")
    assert {item["id"]: item for item in gnews_catalog}["news"]["provider"] == "GNews"
    assert by_id["news"]["transport"] == "HTTPS"
    assert by_id["news"]["auth"] == "X-Api-Key"
    assert by_id["pc_gamer"]["provider"] is None
    assert by_id["printer"]["provider"] is None


def test_admin_ui_exposes_common_navigation_and_human_cadence_units() -> None:
    assert 'data-view="dashboard"' in ADMIN_HTML
    assert 'data-view="weather"' in ADMIN_HTML
    assert 'data-view="news"' in ADMIN_HTML
    assert 'id="newsProvider"' in ADMIN_HTML
    assert '<option value="gnews">GNews v4</option>' in ADMIN_HTML
    assert 'id="newsSources"' in ADMIN_HTML
    assert 'id="newsSearchIn"' in ADMIN_HTML
    assert 'id="newsDomains"' in ADMIN_HTML
    assert 'id="newsExcludeDomains"' in ADMIN_HTML
    assert 'id="newsSortBy"' in ADMIN_HTML
    assert 'data-view="services"' in ADMIN_HTML
    assert 'data-view="logs"' in ADMIN_HTML
    assert 'data-view-panel="logs"' in ADMIN_HTML
    assert 'id="logService"' in ADMIN_HTML
    assert '<option value="all">Tout</option>' in ADMIN_HTML
    assert '/api/logs?service=' in ADMIN_HTML
    assert 'data-view="security"' in ADMIN_HTML
    assert 'Current <span class="hint">minutes</span>' in ADMIN_HTML
    assert 'Daily <span class="hint">minutes</span>' in ADMIN_HTML


def test_news_section_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "pulsedeck.toml"
    base_config(path)
    config = NewsConfig(
        enabled=True,
        mode="everything",
        query="OpenAI",
        search_in="title",
        sources="bbc-news",
        domains="example.com",
        exclude_domains="blocked.example",
        from_date="2026-09-27",
        to_date="2026-09-28",
        lang="en",
        sort_by="relevancy",
        api_key_file=tmp_path / "newsapi_api_key",
    )
    update_news_config(path, config)
    loaded = load_config(path)
    assert loaded.news.enabled is True
    assert loaded.news.mode == "everything"
    assert loaded.news.query == "OpenAI"
    assert loaded.news.search_in == "title"
    assert loaded.news.sources == "bbc-news"
    assert loaded.news.domains == "example.com"
    assert loaded.news.exclude_domains == "blocked.example"
    assert loaded.news.from_date == "2026-09-27"
    assert loaded.news.to_date == "2026-09-28"
    assert loaded.news.sort_by == "relevancy"
    assert loaded.news.api_key_file == tmp_path / "newsapi_api_key"
    assert "[collectors.weather]" in path.read_text(encoding="utf-8")


def test_render_news_documents_header_auth_contract() -> None:
    text = render_news_section(NewsConfig())
    assert 'provider = "newsapi"' in text
    assert 'api_key_file = "/etc/pulsedeck/secrets/newsapi_api_key"' in text
    assert "api_key =" not in text



def test_gnews_section_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "pulsedeck.toml"
    base_config(path)
    config = NewsConfig(
        enabled=True,
        provider="gnews",
        mode="search",
        query="OpenAI",
        country="fr",
        lang="fr",
        search_in="title,description",
        nullable="description,image",
        sort_by="relevance",
        api_key_file=tmp_path / "gnews_api_key",
    )
    update_news_config(path, config)
    loaded = load_config(path)
    assert loaded.news.provider == "gnews"
    assert loaded.news.mode == "search"
    assert loaded.news.nullable == "description,image"
    assert loaded.news.api_key_file == tmp_path / "gnews_api_key"
    text = path.read_text(encoding="utf-8")
    assert 'provider = "gnews"' in text
    assert 'api_key_file = ' in text
