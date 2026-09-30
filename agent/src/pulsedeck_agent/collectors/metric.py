from __future__ import annotations

from dataclasses import dataclass
import time


@dataclass(frozen=True)
class MetricReading:
    raw_value: float | int | None
    source: str
    unit: str
    sampled_at_unix_ms: int
    sampled_at_monotonic_s: float
    read_ok: bool
    read_error: str | None
    estimated: bool = False

    @property
    def valid(self) -> bool:
        return self.read_ok and self.raw_value is not None

    def as_dict(self) -> dict[str, object]:
        value = self.raw_value if self.valid else None
        return {
            "value_raw": value,
            "value_display": value,
            "source": self.source,
            "unit": self.unit,
            "sampled_at": self.sampled_at_unix_ms,
            "estimated": self.estimated,
            "valid": self.valid,
            "error": self.read_error,
        }


def ok_reading(*, value: float | int, source: str, unit: str, estimated: bool = False) -> MetricReading:
    return MetricReading(
        raw_value=value,
        source=source,
        unit=unit,
        sampled_at_unix_ms=int(time.time() * 1000),
        sampled_at_monotonic_s=time.monotonic(),
        read_ok=True,
        read_error=None,
        estimated=estimated,
    )


def failed_reading(*, source: str, unit: str, error: str) -> MetricReading:
    return MetricReading(
        raw_value=None,
        source=source,
        unit=unit,
        sampled_at_unix_ms=int(time.time() * 1000),
        sampled_at_monotonic_s=time.monotonic(),
        read_ok=False,
        read_error=error,
        estimated=False,
    )
