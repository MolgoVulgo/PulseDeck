import io
from pathlib import Path
from urllib.error import HTTPError

import pytest

from pulsedeck_hub.collectors.news import NewsAPIClient, NewsError, normalize_news
from pulsedeck_hub.config import NewsConfig, news_config_from_mapping


def test_news_defaults_are_safe_and_disabled() -> None:
    cfg = news_config_from_mapping({"enabled": False})
    assert cfg.enabled is False
    assert cfg.provider == "newsapi"
    assert cfg.mode == "top-headlines"
    assert cfg.category == "general"
    assert cfg.lang == "fr"
    assert cfg.country == "fr"
    assert cfg.max_articles == 10
    assert cfg.interval == 1800


def test_news_everything_requires_query() -> None:
    with pytest.raises(ValueError, match="query is required"):
        news_config_from_mapping({"enabled": False, "mode": "everything", "query": ""})


def test_newsapi_uses_https_and_x_api_key_header(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True, api_key_file=Path("/unused"))
    client = NewsAPIClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return b'{"status":"ok","totalResults":0,"articles":[]}'

    def fake_open(request, timeout):
        seen["url"] = request.full_url
        seen["headers"] = {k.lower(): v for k, v in request.header_items()}
        seen["timeout"] = timeout
        return FakeResponse()

    monkeypatch.setattr(client._opener, "open", fake_open)
    client.fetch()

    assert seen["url"].startswith("https://newsapi.org/v2/top-headlines?")
    assert "apikey=" not in seen["url"].lower()
    assert seen["headers"]["x-api-key"] == "secret-key"
    assert seen["timeout"] == 15


def test_newsapi_everything_parameters_do_not_contain_secret(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True, mode="everything", query="OpenAI", lang="en", country="us")
    client = NewsAPIClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return b'{"status":"ok","totalResults":0,"articles":[]}'

    def fake_open(request, timeout):
        seen["url"] = request.full_url
        return FakeResponse()

    monkeypatch.setattr(client._opener, "open", fake_open)
    client.fetch()
    assert "/everything?" in seen["url"]
    assert "q=OpenAI" in seen["url"]
    assert "language=en" in seen["url"]
    assert "sortBy=publishedAt" in seen["url"]
    assert "country=" not in seen["url"]
    assert "secret-key" not in seen["url"]


def test_top_headlines_uses_country_category_and_optional_query(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True, mode="top-headlines", query="IA", category="technology", country="fr", lang="en")
    client = NewsAPIClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return b'{"status":"ok","totalResults":0,"articles":[]}'

    def fake_open(request, timeout):
        seen["url"] = request.full_url
        return FakeResponse()

    monkeypatch.setattr(client._opener, "open", fake_open)
    client.fetch()
    assert "country=fr" in seen["url"]
    assert "category=technology" in seen["url"]
    assert "q=IA" in seen["url"]
    assert "language=" not in seen["url"]


def test_normalize_news_keeps_display_fields_and_drops_content(monkeypatch) -> None:
    monkeypatch.setattr("pulsedeck_hub.collectors.news.time.time", lambda: 2000)
    raw = {
        "status": "ok",
        "totalResults": 12,
        "articles": [
            {
                "source": {"id": "src", "name": "Example News"},
                "author": "A. Author",
                "title": "Example",
                "description": "Summary",
                "content": "Provider content is deliberately not republished",
                "url": "https://example.com/story",
                "urlToImage": "https://example.com/image.jpg",
                "publishedAt": "2026-09-27T20:00:00Z",
            }
        ],
    }
    payload = normalize_news(raw, NewsConfig())
    assert payload["schema"] == 1
    assert payload["source"] == "newsapi"
    assert payload["ts"] == 2000
    assert payload["total_results"] == 12
    article = payload["articles"][0]
    assert article["title"] == "Example"
    assert article["description"] == "Summary"
    assert article["author"] == "A. Author"
    assert article["image_url"] == "https://example.com/image.jpg"
    assert article["source"] == {"id": "src", "name": "Example News"}
    assert isinstance(article["published_ts"], int)
    assert "content" not in article


def test_provider_http_error_is_sanitized(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True)
    client = NewsAPIClient(cfg, api_key="secret-key")

    def fake_open(request, timeout):
        raise HTTPError(request.full_url, 401, "Unauthorized", {}, io.BytesIO(b'{"status":"error","message":"bad key"}'))

    monkeypatch.setattr(client._opener, "open", fake_open)
    with pytest.raises(NewsError, match="NewsAPI HTTP 401") as exc:
        client.fetch()
    assert "secret-key" not in str(exc.value)
