import io
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlparse

import pytest

from pulsedeck_hub.collectors.news import NewsAPIClient, NewsError, normalize_news
from pulsedeck_hub.config import NewsConfig, news_config_from_mapping


def _query(url: str) -> dict[str, list[str]]:
    return parse_qs(urlparse(url).query)


def test_news_defaults_match_live_top_headlines() -> None:
    cfg = news_config_from_mapping({"enabled": False})
    assert cfg.enabled is False
    assert cfg.provider == "newsapi"
    assert cfg.mode == "top-headlines"
    assert cfg.country == "fr"
    assert cfg.category == ""
    assert cfg.sources == ""
    assert cfg.lang == "fr"
    assert cfg.sort_by == "publishedAt"
    assert cfg.max_articles == 10
    assert cfg.interval == 1800


def test_everything_query_is_optional() -> None:
    cfg = news_config_from_mapping({"enabled": False, "mode": "everything", "query": ""})
    assert cfg.query == ""


def test_top_headlines_sources_cannot_mix_with_country_or_category() -> None:
    with pytest.raises(ValueError, match="sources cannot be combined"):
        news_config_from_mapping({
            "enabled": False,
            "mode": "top-headlines",
            "sources": "bbc-news",
            "country": "fr",
        })


def test_newsapi_validates_documented_enums_and_source_limit() -> None:
    with pytest.raises(ValueError, match="lang is unsupported"):
        news_config_from_mapping({"enabled": False, "mode": "everything", "lang": "xx"})
    with pytest.raises(ValueError, match="sort_by is unsupported"):
        news_config_from_mapping({"enabled": False, "mode": "everything", "sort_by": "oldest"})
    with pytest.raises(ValueError, match="search_in contains"):
        news_config_from_mapping({"enabled": False, "mode": "everything", "search_in": "title,url"})
    with pytest.raises(ValueError, match="at most 20"):
        news_config_from_mapping({"enabled": False, "mode": "everything", "sources": ",".join(f"s{i}" for i in range(21))})
    top = news_config_from_mapping({"enabled": False, "mode": "top-headlines", "sources": ",".join(f"s{i}" for i in range(21)), "country": "", "category": ""})
    assert len(top.sources.split(",")) == 21


def test_newsapi_uses_https_and_x_api_key_header(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True, api_key_file=Path("/unused"))
    client = NewsAPIClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self): return self
        def __exit__(self, exc_type, exc, tb): return False
        def read(self): return b'{"status":"ok","totalResults":0,"articles":[]}'

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


def test_top_headlines_supports_country_category_query(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True, mode="top-headlines", query="IA", category="technology", country="fr")
    client = NewsAPIClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self): return self
        def __exit__(self, exc_type, exc, tb): return False
        def read(self): return b'{"status":"ok","totalResults":0,"articles":[]}'

    monkeypatch.setattr(client._opener, "open", lambda request, timeout: seen.setdefault("url", request.full_url) or FakeResponse())
    # use explicit function because setdefault returns the URL on second evaluation
    def fake_open(request, timeout):
        seen["url"] = request.full_url
        return FakeResponse()
    monkeypatch.setattr(client._opener, "open", fake_open)
    client.fetch()
    q = _query(seen["url"])
    assert q["country"] == ["fr"]
    assert q["category"] == ["technology"]
    assert q["q"] == ["IA"]
    assert "sources" not in q
    assert "language" not in q


def test_top_headlines_sources_omits_country_and_category(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True, mode="top-headlines", sources="bbc-news,the-verge", country="", category="")
    client = NewsAPIClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self): return self
        def __exit__(self, exc_type, exc, tb): return False
        def read(self): return b'{"status":"ok","totalResults":0,"articles":[]}'

    def fake_open(request, timeout):
        seen["url"] = request.full_url
        return FakeResponse()
    monkeypatch.setattr(client._opener, "open", fake_open)
    client.fetch()
    q = _query(seen["url"])
    assert q["sources"] == ["bbc-news,the-verge"]
    assert "country" not in q
    assert "category" not in q


def test_everything_maps_documented_filters(monkeypatch) -> None:
    cfg = NewsConfig(
        enabled=True,
        mode="everything",
        query="OpenAI",
        search_in="title,description",
        sources="bbc-news",
        domains="example.com,example.org",
        exclude_domains="blocked.example",
        from_date="2026-09-27",
        to_date="2026-09-28T12:00:00Z",
        lang="en",
        sort_by="popularity",
        country="fr",  # deliberately ignored by /everything
        category="technology",  # deliberately ignored by /everything
    )
    client = NewsAPIClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self): return self
        def __exit__(self, exc_type, exc, tb): return False
        def read(self): return b'{"status":"ok","totalResults":0,"articles":[]}'

    def fake_open(request, timeout):
        seen["url"] = request.full_url
        return FakeResponse()
    monkeypatch.setattr(client._opener, "open", fake_open)
    client.fetch()
    q = _query(seen["url"])
    assert q["q"] == ["OpenAI"]
    assert q["searchIn"] == ["title,description"]
    assert q["sources"] == ["bbc-news"]
    assert q["domains"] == ["example.com,example.org"]
    assert q["excludeDomains"] == ["blocked.example"]
    assert q["from"] == ["2026-09-27"]
    assert q["to"] == ["2026-09-28T12:00:00Z"]
    assert q["language"] == ["en"]
    assert q["sortBy"] == ["popularity"]
    assert q["page"] == ["1"]
    assert "country" not in q
    assert "category" not in q
    assert "secret-key" not in seen["url"]


def test_search_in_is_omitted_without_query(monkeypatch) -> None:
    cfg = NewsConfig(enabled=True, mode="everything", query="", search_in="title", domains="example.com")
    client = NewsAPIClient(cfg, api_key="secret-key")
    seen = {}

    class FakeResponse:
        def __enter__(self): return self
        def __exit__(self, exc_type, exc, tb): return False
        def read(self): return b'{"status":"ok","totalResults":0,"articles":[]}'

    def fake_open(request, timeout):
        seen["url"] = request.full_url
        return FakeResponse()
    monkeypatch.setattr(client._opener, "open", fake_open)
    client.fetch()
    q = _query(seen["url"])
    assert "q" not in q
    assert "searchIn" not in q
    assert q["domains"] == ["example.com"]


def test_normalize_news_keeps_display_fields_and_drops_content(monkeypatch) -> None:
    monkeypatch.setattr("pulsedeck_hub.collectors.news.time.time", lambda: 2000)
    raw = {
        "status": "ok",
        "totalResults": 12,
        "articles": [{
            "source": {"id": "src", "name": "Example News"},
            "author": "A. Author",
            "title": "Example",
            "description": "Summary",
            "content": "Provider content is deliberately not republished",
            "url": "https://example.com/story",
            "urlToImage": "https://example.com/image.jpg",
            "publishedAt": "2026-09-27T20:00:00Z",
        }],
    }
    cfg = NewsConfig(mode="everything", query="OpenAI", domains="example.com", sort_by="relevancy")
    payload = normalize_news(raw, cfg)
    assert payload["schema"] == 1
    assert payload["source"] == "newsapi"
    assert payload["ts"] == 2000
    assert payload["total_results"] == 12
    assert payload["feed"]["domains"] == "example.com"
    assert payload["feed"]["sort_by"] == "relevancy"
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
