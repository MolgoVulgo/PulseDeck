from __future__ import annotations

import psutil

from .metric import MetricReading, failed_reading, ok_reading


def collect_memory() -> dict[str, MetricReading]:
    source = "psutil.virtual_memory()"
    try:
        vm = psutil.virtual_memory()
    except Exception as exc:  # pragma: no cover - defensive path
        error = f"read_error:{type(exc).__name__}:{exc}"
        return {
            "used_b": failed_reading(source=source, unit="bytes", error=error),
            "total_b": failed_reading(source=source, unit="bytes", error=error),
            "pct": failed_reading(source=source, unit="percent", error=error),
        }

    return {
        "used_b": ok_reading(value=int(vm.used), source=source, unit="bytes"),
        "total_b": ok_reading(value=int(vm.total), source=source, unit="bytes"),
        "pct": ok_reading(value=float(vm.percent), source=source, unit="percent"),
    }
