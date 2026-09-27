"""FastAPI server lifecycle for PulseDeck Admin."""

from __future__ import annotations

import logging
import threading
from typing import Any

from fastapi import FastAPI
import uvicorn

from .routes import install_routes


LOG = logging.getLogger(__name__)


class AdminServer:
    def __init__(self, runtime: Any) -> None:
        self.runtime = runtime
        self.app = FastAPI(title="PulseDeck Admin", docs_url=None, redoc_url=None, openapi_url=None)
        install_routes(self.app, runtime)
        config = uvicorn.Config(
            self.app,
            host=runtime.config.admin.listen,
            port=runtime.config.admin.port,
            log_level="warning",
            access_log=False,
        )
        self.server = uvicorn.Server(config)
        self._thread = threading.Thread(target=self.server.run, name="pulsedeck-admin", daemon=True)

    def start(self) -> None:
        LOG.info("Starting Web Admin on http://%s:%s", self.runtime.config.admin.listen, self.runtime.config.admin.port)
        self._thread.start()

    def stop(self) -> None:
        self.server.should_exit = True
        if self._thread.is_alive():
            self._thread.join(timeout=5.0)
