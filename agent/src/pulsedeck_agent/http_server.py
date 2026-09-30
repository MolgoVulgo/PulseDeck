from __future__ import annotations

from collections.abc import Callable
from copy import deepcopy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import threading
import time
from typing import Any


LOG = logging.getLogger(__name__)
PROTOCOL_NAME = "pulsedeck-agent-http"
WIRE_SCHEMA = 1
SNAPSHOT_PATH = "/v1/snapshot"
HEALTH_PATH = "/v1/health"


def build_wire_payload(snapshot: dict[str, object]) -> dict[str, object]:
    """Wrap the local diagnostic model in an explicit Agent -> Pi wire contract."""
    return {
        "schema": WIRE_SCHEMA,
        "protocol": PROTOCOL_NAME,
        "ts": int(time.time()),
        "snapshot": deepcopy(snapshot),
    }


class AgentHTTPServer:
    def __init__(
        self,
        listen: str,
        port: int,
        snapshot_provider: Callable[[], dict[str, object] | None],
    ) -> None:
        self.listen = listen
        self.port = port
        self.snapshot_provider = snapshot_provider
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def bound_port(self) -> int | None:
        if self._server is None:
            return None
        return int(self._server.server_address[1])

    def start(self) -> None:
        if self._server is not None:
            return
        snapshot_provider = self.snapshot_provider

        class Handler(BaseHTTPRequestHandler):
            server_version = "PulseDeckAgent/1"

            def log_message(self, fmt: str, *args: Any) -> None:
                LOG.debug("Agent HTTP: " + fmt, *args)

            def do_GET(self) -> None:  # noqa: N802
                if self.path == HEALTH_PATH:
                    self._json_response(200, {"schema": WIRE_SCHEMA, "state": "online", "ts": int(time.time())})
                    return
                if self.path != SNAPSHOT_PATH:
                    self._json_response(404, {"schema": WIRE_SCHEMA, "error": "not_found"})
                    return
                snapshot = snapshot_provider()
                if snapshot is None:
                    self._json_response(503, {"schema": WIRE_SCHEMA, "error": "snapshot_unavailable"})
                    return
                self._json_response(200, build_wire_payload(snapshot))

            def _json_response(self, status: int, payload: dict[str, object]) -> None:
                body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

        self._server = ThreadingHTTPServer((self.listen, self.port), Handler)
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, name="pulsedeck-agent-http", daemon=True)
        self._thread.start()
        LOG.info("Agent HTTP transport listening on %s:%s", self.listen, self.bound_port)

    def stop(self) -> None:
        server = self._server
        thread = self._thread
        self._server = None
        self._thread = None
        if server is None:
            return
        server.shutdown()
        server.server_close()
        if thread is not None:
            thread.join(timeout=2.0)
