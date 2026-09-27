import io
import json
from pathlib import Path
from urllib.error import HTTPError

import pytest

from pulsedeck_hub.collectors.news import GNewsClient, NewsError, normalize_news
from pulsedeck_hub.config import NewsConfig, news_config_from_mapping


def test_news_defaults_are_safe_and_disabled() -> None:
    cfg = news_config_from_mapping({"enabled": False})
    assert cfg.enabled is False
    assert cfg.provider == "gnews"
    assert cfg.mode == "top-headlines"
    assert cfg.category == "general"
    assert cfg.lang == "fr"
    assert cfg.country == "fr"
    assert cfg.max_articles == 10
    assert cfg.interval == 1800


def test_news_search_requires_query() -> None:
    with pytest.raises(ValueError, match="query is required"):
        news_config_from_mapping({"enabled": False, "mode": "search", "query": ""})


def test_gnews_uses_https_and_x_api_key_header(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True, api_key_file=Path("/unused"))
    client = GNewsClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return b'{"totalArticles":0,"articles":[]}'

    def fake_open(request, timeout):
        seen["url"] = request.full_url
        seen["headers"] = {k.lower(): v for k, v in request.header_items()}
        seen["timeout"] = timeout
        return FakeResponse()

    monkeypatch.setattr(client._opener, "open", fake_open)
    client.fetch()

    assert seen["url"].startswith("https://gnews.io/api/v4/top-headlines?")
    assert "apikey=" not in seen["url"].lower()
    assert seen["headers"]["x-api-key"] == "secret-key"
    assert seen["timeout"] == 15


def test_gnews_search_parameters_do_not_contain_secret(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True, mode="search", query="OpenAI", lang="en", country="us")
    client = GNewsClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def read(self):
            return b'{"totalArticles":0,"articles":[]}'

    def fake_open(request, timeout):
        seen["url"] = request.full_url
        return FakeResponse()

    monkeypatch.setattr(client._opener, "open", fake_open)
    client.fetch()
    assert "/search?" in seen["url"]
    assert "q=OpenAI" in seen["url"]
    assert "sortby=publishedAt" in seen["url"]
    assert "secret-key" not in seen["url"]


def test_normalize_news_keeps_display_fields_and_drops_content(monkeypatch) -> None:
    monkeypatch.setattr("pulsedeck_hub.collectors.news.time.time", lambda: 2000)
    raw = {
        "totalArticles": 12,
        "articles": [
            {
                "id": "abc",
                "title": "Example",
                "description": "Summary",
                "content": "Long provider content must not be republished",
                "url": "https://example.com/story",
                "image": "https://example.com/image.jpg",
                "publishedAt": "2026-09-27T20:00:00Z",
                "lang": "en",
                "source": {"id": "src", "name": "Example News", "url": "https://example.com", "country": "us"},
            }
        ],
    }
    payload = normalize_news(raw, NewsConfig())
    assert payload["schema"] == 1
    assert payload["source"] == "gnews"
    assert payload["ts"] == 2000
    assert payload["total_articles"] == 12
    article = payload["articles"][0]
    assert article["title"] == "Example"
    assert article["description"] == "Summary"
    assert article["image_url"] == "https://example.com/image.jpg"
    assert isinstance(article["published_ts"], int)
    assert "content" not in article


def test_provider_http_error_is_sanitized(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True)
    client = GNewsClient(cfg, api_key="secret-key")

    def fake_open(request, timeout):
        raise HTTPError(request.full_url, 401, "Unauthorized", {}, io.BytesIO(b'{"errors":["bad key"]}'))

    monkeypatch.setattr(client._opener, "open", fake_open)
    with pytest.raises(NewsError, match="GNews HTTP 401") as exc:
        client.fetch()
    assert "secret-key" not in str(exc.value)
