from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import socket
import time

import psutil

from .metric import MetricReading, failed_reading, ok_reading


@dataclass(frozen=True)
class CounterSample:
    monotonic_s: float
    rx_bytes: int
    tx_bytes: int


class NetworkCollector:
    def __init__(self, interface: str) -> None:
        self.requested_interface = interface
        self.interface = resolve_interface(interface)
        self._previous: CounterSample | None = None

    def collect(self) -> dict[str, MetricReading | str]:
        source = f"psutil.net_io_counters(pernic=True)[{self.interface}]"
        try:
            counters = psutil.net_io_counters(pernic=True).get(self.interface)
        except Exception as exc:  # pragma: no cover - defensive path
            counters = None
            error = f"read_error:{type(exc).__name__}:{exc}"
        else:
            error = "interface_missing" if counters is None else ""

        if counters is None:
            return {
                "interface": self.interface,
                "rx_bps": failed_reading(source=source, unit="bytes_per_second", error=error),
                "tx_bps": failed_reading(source=source, unit="bytes_per_second", error=error),
                "rx_bytes": failed_reading(source=source, unit="bytes", error=error),
                "tx_bytes": failed_reading(source=source, unit="bytes", error=error),
            }

        now = time.monotonic()
        current = CounterSample(now, int(counters.bytes_recv), int(counters.bytes_sent))
        rx_bps, tx_bps = rates_from_samples(self._previous, current, source=source)
        self._previous = current

        return {
            "interface": self.interface,
            "rx_bps": rx_bps,
            "tx_bps": tx_bps,
            "rx_bytes": ok_reading(value=current.rx_bytes, source=source, unit="bytes"),
            "tx_bytes": ok_reading(value=current.tx_bytes, source=source, unit="bytes"),
        }


def rates_from_samples(
    previous: CounterSample | None,
    current: CounterSample,
    *,
    source: str,
) -> tuple[MetricReading, MetricReading]:
    if previous is None:
        return (
            failed_reading(source=source, unit="bytes_per_second", error="warmup_required"),
            failed_reading(source=source, unit="bytes_per_second", error="warmup_required"),
        )

    elapsed = current.monotonic_s - previous.monotonic_s
    if elapsed <= 0:
        return (
            failed_reading(source=source, unit="bytes_per_second", error="invalid_elapsed_time"),
            failed_reading(source=source, unit="bytes_per_second", error="invalid_elapsed_time"),
        )

    rx_delta = current.rx_bytes - previous.rx_bytes
    tx_delta = current.tx_bytes - previous.tx_bytes
    if rx_delta < 0 or tx_delta < 0:
        return (
            failed_reading(source=source, unit="bytes_per_second", error="counter_reset"),
            failed_reading(source=source, unit="bytes_per_second", error="counter_reset"),
        )

    return (
        ok_reading(value=rx_delta / elapsed, source=source, unit="bytes_per_second"),
        ok_reading(value=tx_delta / elapsed, source=source, unit="bytes_per_second"),
    )


def resolve_interface(configured: str) -> str:
    if configured != "auto":
        return configured

    route = _default_route_interface()
    if route:
        return route

    stats = psutil.net_if_stats()
    for name, stat in stats.items():
        if name != "lo" and stat.isup:
            return name

    names = [name for _, name in socket.if_nameindex() if name != "lo"]
    if names:
        return sorted(names)[0]
    return "lo"


def _default_route_interface() -> str | None:
    route_path = Path("/proc/net/route")
    try:
        lines = route_path.read_text(encoding="utf-8").splitlines()[1:]
    except OSError:
        return None
    for line in lines:
        fields = line.split()
        if len(fields) >= 4 and fields[1] == "00000000":
            try:
                flags = int(fields[3], 16)
            except ValueError:
                continue
            if flags & 0x1:
                return fields[0]
    return None
