"""Shared collector lifecycle contract."""

from __future__ import annotations

from typing import Protocol


class Collector(Protocol):
    def start(self) -> None: ...

    def stop(self) -> None: ...
