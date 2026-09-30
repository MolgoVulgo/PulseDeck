from __future__ import annotations

from collections.abc import Iterable
from pathlib import Path

import psutil

from .metric import MetricReading, failed_reading, ok_reading


HWMON_CLASS_PATH = Path("/sys/class/hwmon")
POWERCAP_CLASS_PATH = Path("/sys/class/powercap")


def collect_cpu() -> dict[str, MetricReading]:
    return {
        "pct": read_cpu_percent_metric(),
        "temp_c": read_cpu_temp_metric(),
        "power_w": read_cpu_power_metric(),
    }


def read_cpu_percent_metric() -> MetricReading:
    source = "psutil.cpu_percent(interval=0.1)"
    try:
        value = float(psutil.cpu_percent(interval=0.1))
        return ok_reading(value=value, source=source, unit="percent")
    except Exception as exc:  # pragma: no cover - defensive path
        return failed_reading(source=source, unit="percent", error=f"read_error:{type(exc).__name__}:{exc}")


def read_cpu_temp_metric() -> MetricReading:
    source = "psutil.sensors_temperatures(fahrenheit=False)"
    try:
        temperatures = psutil.sensors_temperatures(fahrenheit=False)
    except Exception as exc:  # pragma: no cover - defensive path
        return failed_reading(source=source, unit="celsius", error=f"read_error:{type(exc).__name__}:{exc}")

    if not temperatures:
        return failed_reading(source=source, unit="celsius", error="sensor_missing:no_temperatures")

    sensor_groups: list[Iterable] = []
    for name, entries in temperatures.items():
        if "k10temp" in name.lower():
            sensor_groups.append(entries)
    sensor_groups.extend(entries for entries in temperatures.values())

    for label in ("tdie", "tctl"):
        value = _find_label_temp(sensor_groups, label)
        if value is not None:
            return ok_reading(value=value, source=f"{source}:{label}", unit="celsius")

    # Non-AMD hosts may expose a usable package/core temperature under a different label.
    for entries in sensor_groups:
        for entry in entries:
            current = getattr(entry, "current", None)
            if current is not None:
                label = (getattr(entry, "label", "") or "generic").strip() or "generic"
                return ok_reading(value=float(current), source=f"{source}:{label}", unit="celsius")

    return failed_reading(source=source, unit="celsius", error="sensor_missing")


def read_cpu_power_metric() -> MetricReading:
    direct = _read_cpu_power_from_hwmon()
    if direct is not None:
        return direct

    if POWERCAP_CLASS_PATH.exists() and any(POWERCAP_CLASS_PATH.glob("*/energy_uj")):
        return failed_reading(
            source="/sys/class/powercap/*/energy_uj",
            unit="watt",
            error="source_present_but_no_instantaneous_power",
        )

    return failed_reading(
        source="/sys/class/hwmon/*/power1_average",
        unit="watt",
        error="source_unavailable",
    )


def _find_label_temp(groups: Iterable[Iterable], label: str) -> float | None:
    wanted = label.lower()
    for entries in groups:
        for entry in entries:
            entry_label = (getattr(entry, "label", "") or "").lower()
            current = getattr(entry, "current", None)
            if entry_label == wanted and current is not None:
                return float(current)
    return None


def _read_cpu_power_from_hwmon() -> MetricReading | None:
    if not HWMON_CLASS_PATH.exists():
        return None

    # Prefer k10temp (PulseMon's existing AMD path), then accept another hwmon
    # source only when it exposes a direct instantaneous/average power value.
    dirs = sorted(HWMON_CLASS_PATH.glob("hwmon*"))
    ranked: list[Path] = []
    others: list[Path] = []
    for hwmon_dir in dirs:
        try:
            name = (hwmon_dir / "name").read_text(encoding="utf-8").strip().lower()
        except OSError:
            name = ""
        (ranked if name == "k10temp" else others).append(hwmon_dir)

    for hwmon_dir in ranked + others:
        for filename in ("power1_average", "power1_input"):
            power_path = hwmon_dir / filename
            if not power_path.exists():
                continue
            try:
                value_uw = float(power_path.read_text(encoding="utf-8").strip())
            except ValueError:
                return failed_reading(source=str(power_path), unit="watt", error="invalid_value")
            except OSError as exc:
                return failed_reading(
                    source=str(power_path), unit="watt", error=f"read_error:{type(exc).__name__}:{exc}"
                )
            return ok_reading(value=value_uw / 1_000_000.0, source=str(power_path), unit="watt")
    return None
