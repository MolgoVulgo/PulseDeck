"""NewsAPI collector for PulseDeck News V1."""

from __future__ import annotations

from datetime import datetime
import json
import logging
import threading
import time
from typing import TYPE_CHECKING, Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from ..config import NewsConfig
from ..mqtt.payloads import encode_payload, source_availability_payload

if TYPE_CHECKING:
    from ..health.state import HealthState
    from ..mqtt.client import HubMQTTClient


LOG = logging.getLogger(__name__)
SOURCE = "newsapi"
API_ROOT = "https://newsapi.org/v2"


class NewsError(RuntimeError):
    """Sanitized NewsAPI provider or publication failure."""


class _RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


class NewsAPIClient:
    def __init__(self, config: NewsConfig, *, api_key: str | None = None) -> None:
        self.config = config
        self._api_key_override = api_key
        self._opener = build_opener(_RejectRedirects)

    def _api_key(self) -> str:
        if self._api_key_override is not None:
            key = self._api_key_override.strip()
        else:
            try:
                key = self.config.api_key_file.read_text(encoding="utf-8").strip()
            except OSError as exc:
                raise NewsError(f"API key file unavailable: {self.config.api_key_file}") from exc
        if not key:
            raise NewsError("NewsAPI API key is empty")
        return key

    def _params(self) -> dict[str, object]:
        params: dict[str, object] = {"pageSize": self.config.max_articles, "page": 1}
        if self.config.mode == "top-headlines":
            if self.config.sources:
                params["sources"] = self.config.sources
            else:
                if self.config.country:
                    params["country"] = self.config.country
                if self.config.category:
                    params["category"] = self.config.category
            if self.config.query:
                params["q"] = self.config.query
        else:
            if self.config.query:
                params["q"] = self.config.query
                if self.config.search_in:
                    params["searchIn"] = self.config.search_in
            if self.config.sources:
                params["sources"] = self.config.sources
            if self.config.domains:
                params["domains"] = self.config.domains
            if self.config.exclude_domains:
                params["excludeDomains"] = self.config.exclude_domains
            if self.config.from_date:
                params["from"] = self.config.from_date
            if self.config.to_date:
                params["to"] = self.config.to_date
            if self.config.lang:
                params["language"] = self.config.lang
            if self.config.sort_by:
                params["sortBy"] = self.config.sort_by
        return params

    def fetch(self) -> dict[str, Any]:
        endpoint = "top-headlines" if self.config.mode == "top-headlines" else "everything"
        url = f"{API_ROOT}/{endpoint}?{urlencode(self._params())}"
        request = Request(
            url,
            headers={
                "Accept": "application/json",
                "User-Agent": "PulseDeck/0.4.1",
                "X-Api-Key": self._api_key(),
            },
        )
        try:
            with self._opener.open(request, timeout=self.config.request_timeout) as response:
                body = response.read()
        except HTTPError as exc:
            raise NewsError(f"NewsAPI HTTP {exc.code}") from exc
        except URLError as exc:
            reason = getattr(exc, "reason", None)
            raise NewsError(f"NewsAPI network error: {type(reason).__name__ if reason else 'unknown'}") from exc
        except TimeoutError as exc:
            raise NewsError("NewsAPI request timed out") from exc

        try:
            raw = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise NewsError("NewsAPI returned invalid JSON") from exc
        if not isinstance(raw, dict):
            raise NewsError("NewsAPI returned an unexpected response")
        if raw.get("status") != "ok":
            code = raw.get("code")
            raise NewsError(f"NewsAPI provider error{f' ({code})' if isinstance(code, str) and code else ''}")
        articles = raw.get("articles")
        if not isinstance(articles, list):
            raise NewsError("NewsAPI response contains no articles array")
        return raw


def _published_ts(value: object) -> int | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return int(parsed.timestamp())


def normalize_news(raw: dict[str, Any], config: NewsConfig) -> dict[str, object]:
    articles_raw = raw.get("articles")
    if not isinstance(articles_raw, list):
        raise NewsError("NewsAPI response contains no articles array")

    articles: list[dict[str, object]] = []
    for raw_article in articles_raw[: config.max_articles]:
        if not isinstance(raw_article, dict):
            continue
        title = raw_article.get("title")
        url = raw_article.get("url")
        published = _published_ts(raw_article.get("publishedAt"))
        if not isinstance(title, str) or not title or not isinstance(url, str) or not url or published is None:
            continue

        item: dict[str, object] = {
            "title": title,
            "url": url,
            "published_ts": published,
        }
        for provider_key, target_key in (
            ("author", "author"),
            ("description", "description"),
            ("urlToImage", "image_url"),
        ):
            value = raw_article.get(provider_key)
            if isinstance(value, str) and value:
                item[target_key] = value

        source_raw = raw_article.get("source")
        if isinstance(source_raw, dict):
            source: dict[str, object] = {}
            for provider_key in ("id", "name"):
                value = source_raw.get(provider_key)
                if isinstance(value, str) and value:
                    source[provider_key] = value
            if source:
                item["source"] = source
        articles.append(item)

    total_results = raw.get("totalResults")
    payload: dict[str, object] = {
        "schema": 1,
        "source": SOURCE,
        "ts": int(time.time()),
        "feed": {
            "mode": config.mode,
            "query": config.query or None,
            "sources": config.sources or None,
            "country": config.country if config.mode == "top-headlines" and not config.sources else None,
            "category": config.category if config.mode == "top-headlines" and not config.sources else None,
            "search_in": config.search_in if config.mode == "everything" else None,
            "domains": config.domains if config.mode == "everything" else None,
            "exclude_domains": config.exclude_domains if config.mode == "everything" else None,
            "from": config.from_date if config.mode == "everything" else None,
            "to": config.to_date if config.mode == "everything" else None,
            "language": config.lang if config.mode == "everything" else None,
            "sort_by": config.sort_by if config.mode == "everything" else None,
        },
        "articles": articles,
    }
    if isinstance(total_results, int) and not isinstance(total_results, bool):
        payload["total_results"] = total_results
    return payload


class NewsCollector:
    def __init__(self, config: NewsConfig, mqtt_client: "HubMQTTClient", health: "HealthState | None" = None) -> None:
        self.config = config
        self.mqtt = mqtt_client
        self.health = health
        self.provider = NewsAPIClient(config)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="news-collector", daemon=True)
        self._last_success: int | None = None

    def start(self) -> None:
        LOG.info("Starting News collector: NewsAPI %s", self.config.mode)
        if self.health is not None:
            self.health.news_started()
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(timeout=float(self.config.request_timeout) + 2.0)
        self._publish_availability("offline", reason="collector_stopped")
        if self.health is not None:
            self.health.news_stopped()

    def _publish_availability(self, state: str, *, reason: str | None = None) -> None:
        payload = source_availability_payload(
            state,
            source=SOURCE,
            last_success=self._last_success,
            reason=reason,
        )
        if not self.mqtt.publish_retained("news/availability", payload):
            LOG.debug("News availability not published because MQTT is unavailable")

    def _fetch_latest(self) -> None:
        raw = self.provider.fetch()
        payload = normalize_news(raw, self.config)
        articles = payload.get("articles")
        count = len(articles) if isinstance(articles, list) else 0
        if not self.mqtt.publish_retained("news/latest", encode_payload(payload)):
            raise NewsError("MQTT publish unavailable for news/latest")
        self._last_success = int(time.time())
        self._publish_availability("online")
        if self.health is not None:
            self.health.news_success(count)
        LOG.info("News updated: %d articles", count)

    def _run(self) -> None:
        self._publish_availability("offline", reason="starting")
        next_fetch = 0.0
        retry_delay = min(300.0, max(60.0, float(self.config.interval) / 3.0))

        while not self._stop.is_set():
            if not self.mqtt.connected.wait(timeout=5.0):
                continue

            now = time.monotonic()
            if now >= next_fetch:
                try:
                    self._fetch_latest()
                    next_fetch = now + self.config.interval
                except NewsError as exc:
                    LOG.warning("News failed: %s", exc)
                    if self.health is not None:
                        self.health.news_error(str(exc))
                    self._publish_availability("offline", reason=str(exc))
                    next_fetch = now + retry_delay

            delay = max(1.0, min(30.0, next_fetch - time.monotonic()))
            self._stop.wait(delay)
