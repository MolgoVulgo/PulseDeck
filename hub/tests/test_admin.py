from pathlib import Path

from pulsedeck_hub.admin.catalog import build_service_catalog
from pulsedeck_hub.admin.routes import _printer_runtime_snapshot, _retained_messages
from pulsedeck_hub.admin.ui import ADMIN_HTML
from pulsedeck_hub.admin.security import hash_password, make_session, verify_password, verify_session
from pulsedeck_hub.admin.storage import (
    render_news_section,
    render_printer_section,
    render_weather_section,
    update_news_config,
    update_printer_config,
    update_secret,
    update_weather_config,
)
from pulsedeck_hub.config import NewsConfig, PrinterConfig, PrinterDeviceConfig, WeatherConfig, load_config


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
    assert by_id["printer"]["available"] is True
    assert by_id["printer"]["provider"] == "ELEGOO CC2"
    assert by_id["printer"]["view"] == "printer"
    printer_catalog = build_service_catalog(
        {"state": "online"},
        True,
        {"state": "online"},
        True,
        "newsapi",
        {"state": "degraded"},
        True,
    )
    assert {item["id"]: item for item in printer_catalog}["printer"]["state"] == "degraded"


def test_admin_ui_exposes_common_navigation_and_human_cadence_units() -> None:
    assert 'data-view="dashboard"' in ADMIN_HTML
    assert 'data-view="weather"' in ADMIN_HTML
    assert 'data-view="news"' in ADMIN_HTML
    assert 'data-view="printer"' in ADMIN_HTML
    assert 'data-view-panel="printer"' in ADMIN_HTML
    assert 'id="printerDevices"' in ADMIN_HTML
    assert 'id="printerRuntimeList"' in ADMIN_HTML
    assert '/api/printer/config' in ADMIN_HTML
    assert '/api/printer/test' in ADMIN_HTML
    assert '/api/printer/runtime' in ADMIN_HTML
    assert 'data-view="data"' in ADMIN_HTML
    assert 'data-view-panel="data"' in ADMIN_HTML
    assert 'id="refreshDataButton"' in ADMIN_HTML
    assert '/api/data' in ADMIN_HTML
    assert 'aucun appel fournisseur' in ADMIN_HTML.lower()
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
    assert '<option value="printer">Printer</option>' in ADMIN_HTML
    assert '/api/logs?service=' in ADMIN_HTML
    assert 'data-view="security"' in ADMIN_HTML
    assert 'Current <span class="hint">minutes</span>' in ADMIN_HTML
    assert 'Daily <span class="hint">minutes</span>' in ADMIN_HTML
    assert 'id="installUpdateButton"' in ADMIN_HTML
    assert '/api/update/install' in ADMIN_HTML
    assert 'Installer la mise à jour' in ADMIN_HTML
    assert 'id="updateModal"' in ADMIN_HTML
    assert 'id="updateModalConfirm"' in ADMIN_HTML
    assert 'data-update-step="restart"' in ADMIN_HTML
    assert 'reconnexion automatique' in ADMIN_HTML.lower()
    assert "restartSeen:false" in ADMIN_HTML
    assert ADMIN_HTML.count("state.updateModal.restartSeen=true") >= 2
    assert "inst.state==='running'&&m.restartSeen" in ADMIN_HTML
    assert "setUpdateSteps('done','done','done','active')" in ADMIN_HTML
    assert "$('updateModalTitle').textContent='Vérification finale'" in ADMIN_HTML
    restart_verify = ADMIN_HTML.index("if(inst.state==='running'&&m.restartSeen)")
    generic_running = ADMIN_HTML.index("if(inst.state==='running'){", restart_verify)
    assert restart_verify < generic_running
    assert "confirm('Installer" not in ADMIN_HTML


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

def test_retained_messages_decode_confirmed_publications() -> None:
    class MQTT:
        def retained_snapshot(self, prefix: str):  # type: ignore[no-untyped-def]
            assert prefix == "weather"
            return {
                "weather/current": {
                    "topic": "pulsedeck/v1/weather/current",
                    "payload": '{"schema":1,"data":{"temperature_c":18.5}}',
                    "published_at": 123,
                    "qos": 1,
                },
                "weather/hourly": {
                    "topic": "pulsedeck/v1/weather/hourly",
                    "payload": "not-json",
                    "published_at": 124,
                    "qos": 1,
                },
            }

    class Runtime:
        mqtt_client = MQTT()

    messages = _retained_messages(Runtime(), "weather")
    assert [item["suffix"] for item in messages] == ["weather/current", "weather/hourly"]
    assert messages[0]["payload"]["data"]["temperature_c"] == 18.5
    assert messages[1]["payload"] == "not-json"

def test_printer_section_round_trip_preserves_following_sections(tmp_path: Path) -> None:
    path = tmp_path / "pulsedeck.toml"
    base_config(path)
    path.write_text(
        path.read_text(encoding="utf-8")
        + "\n[collectors.printer]\nenabled = false\n\n[[collectors.printer.devices]]\nid = \"old\"\nhost = \"old.local\"\nserial = \"OLD\"\naccess_code_file = \"/tmp/old\"\n\n[collectors.pc_gamer]\nenabled = false\n",
        encoding="utf-8",
    )
    device = PrinterDeviceConfig(
        id="cc2-main",
        driver="elegoo_cc2",
        host="192.168.1.50",
        serial="ELEGOO123",
        access_code_file=tmp_path / "cc2-main.code",
        reconnect_min_delay=3,
        reconnect_max_delay=20,
    )
    config = PrinterConfig(enabled=True, devices=(device,), poll_interval=4, request_timeout=7)
    update_printer_config(path, config)
    loaded = load_config(path)
    assert loaded.printer.enabled is True
    assert loaded.printer.poll_interval == 4
    assert loaded.printer.request_timeout == 7
    assert [item.id for item in loaded.printer.devices] == ["cc2-main"]
    text = path.read_text(encoding="utf-8")
    assert text.count("[[collectors.printer.devices]]") == 1
    assert '[collectors.pc_gamer]\nenabled = false' in text
    assert "access_code =" not in render_printer_section(config)


def test_printer_runtime_snapshot_uses_normalized_retained_messages(tmp_path: Path) -> None:
    device = PrinterDeviceConfig(
        id="cc2-main",
        driver="elegoo_cc2",
        host="printer.local",
        serial="ELEGOO123",
        access_code_file=tmp_path / "code",
    )

    class MQTT:
        def retained_snapshot(self, prefix: str):  # type: ignore[no-untyped-def]
            assert prefix == "printer"
            return {
                "printer/cc2-main/availability": {
                    "topic": "pulsedeck/v1/printer/cc2-main/availability",
                    "payload": '{"state":"online","last_success":100}',
                    "published_at": 101,
                    "qos": 1,
                },
                "printer/cc2-main/status": {
                    "topic": "pulsedeck/v1/printer/cc2-main/status",
                    "payload": '{"state":"printing","temperatures":{}}',
                    "published_at": 102,
                    "qos": 1,
                },
                "printer/cc2-main/job": {
                    "topic": "pulsedeck/v1/printer/cc2-main/job",
                    "payload": '{"filename":"piece.gcode","current_layer":12,"total_layers":99}',
                    "published_at": 103,
                    "qos": 1,
                },
            }

    class Config:
        printer = PrinterConfig(enabled=True, devices=(device,))

    class Runtime:
        config = Config()
        mqtt_client = MQTT()

    snapshot = _printer_runtime_snapshot(Runtime())
    assert snapshot["state"] == "online"
    assert snapshot["online_devices"] == 1
    assert snapshot["devices"][0]["job"]["filename"] == "piece.gcode"

