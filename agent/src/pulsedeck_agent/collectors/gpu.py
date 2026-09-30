from __future__ import annotations

from pathlib import Path
import re

from .metric import MetricReading, failed_reading, ok_reading


DRM_CLASS_PATH = Path("/sys/class/drm")
CARD_NAME_RE = re.compile(r"^card[0-9]+$")
AMD_VENDOR_ID = "0x1002"


class AmdGpuCollector:
    """AMD sysfs collector derived from the existing PulseMon GPU collector."""

    def __init__(self, *, pci_slot: str | None, temperature_labels: tuple[str, ...]) -> None:
        self.pci_slot = pci_slot
        self.temperature_labels = temperature_labels

    def collect(self) -> dict[str, MetricReading]:
        mapping = _select_mapping(self.pci_slot)
        if mapping is None:
            return _all_failed("no_amd_gpu")

        device, hwmon = mapping
        return {
            "pct": _read_float(device / "gpu_busy_percent", "percent"),
            "temp_c": _read_temperature(hwmon, self.temperature_labels),
            "power_w": _read_power(hwmon),
            "core_clock_mhz": _read_active_clock(device / "pp_dpm_sclk"),
            "mem_clock_mhz": _read_active_clock(device / "pp_dpm_mclk"),
            "vram_used_b": _read_int(device / "mem_info_vram_used", "bytes"),
            "vram_total_b": _read_int(device / "mem_info_vram_total", "bytes"),
            "fan_rpm": _read_first_int(hwmon, "fan*_input", "rpm"),
            "fan_pct": _read_fan_percent(hwmon),
        }


def _all_failed(error: str) -> dict[str, MetricReading]:
    specs = {
        "pct": ("/sys/class/drm/card*/device/gpu_busy_percent", "percent"),
        "temp_c": ("/sys/class/drm/card*/device/hwmon/hwmon*/temp*_input", "celsius"),
        "power_w": ("/sys/class/drm/card*/device/hwmon/hwmon*/power1_average", "watt"),
        "core_clock_mhz": ("/sys/class/drm/card*/device/pp_dpm_sclk", "mhz"),
        "mem_clock_mhz": ("/sys/class/drm/card*/device/pp_dpm_mclk", "mhz"),
        "vram_used_b": ("/sys/class/drm/card*/device/mem_info_vram_used", "bytes"),
        "vram_total_b": ("/sys/class/drm/card*/device/mem_info_vram_total", "bytes"),
        "fan_rpm": ("/sys/class/drm/card*/device/hwmon/hwmon*/fan*_input", "rpm"),
        "fan_pct": ("/sys/class/drm/card*/device/hwmon/hwmon*/pwm1", "percent"),
    }
    return {key: failed_reading(source=source, unit=unit, error=error) for key, (source, unit) in specs.items()}


def _select_mapping(forced_pci_slot: str | None) -> tuple[Path, Path | None] | None:
    mappings: list[tuple[Path, Path | None, str | None, bool]] = []
    if not DRM_CLASS_PATH.exists():
        return None

    for card in sorted(DRM_CLASS_PATH.iterdir()):
        if not card.is_dir() or not CARD_NAME_RE.match(card.name):
            continue
        device_link = card / "device"
        if not device_link.exists():
            continue
        try:
            device = device_link.resolve()
        except OSError:
            continue
        if (_read_text(device / "vendor") or "").lower() != AMD_VENDOR_ID:
            continue
        hwmon_entries = sorted((device / "hwmon").glob("hwmon*")) if (device / "hwmon").exists() else []
        hwmon = hwmon_entries[0].resolve() if hwmon_entries else None
        slot = _read_pci_slot(device)
        mappings.append((device, hwmon, slot, (device / "gpu_busy_percent").exists()))

    if forced_pci_slot:
        for device, hwmon, slot, _ in mappings:
            if slot == forced_pci_slot:
                return device, hwmon
    for device, hwmon, _, has_busy in mappings:
        if has_busy:
            return device, hwmon
    return (mappings[0][0], mappings[0][1]) if mappings else None


def _read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return None


def _read_pci_slot(device: Path) -> str | None:
    uevent = _read_text(device / "uevent")
    if uevent:
        for line in uevent.splitlines():
            if line.startswith("PCI_SLOT_NAME="):
                return line.split("=", 1)[1].lower()
    return device.name.lower() if ":" in device.name else None


def _read_float(path: Path, unit: str) -> MetricReading:
    if not path.exists():
        return failed_reading(source=str(path), unit=unit, error="source_missing")
    try:
        return ok_reading(value=float(path.read_text(encoding="utf-8").strip()), source=str(path), unit=unit)
    except ValueError:
        return failed_reading(source=str(path), unit=unit, error="invalid_value")
    except OSError as exc:
        return failed_reading(source=str(path), unit=unit, error=f"read_error:{type(exc).__name__}:{exc}")


def _read_int(path: Path, unit: str) -> MetricReading:
    if not path.exists():
        return failed_reading(source=str(path), unit=unit, error="source_missing")
    try:
        return ok_reading(value=int(path.read_text(encoding="utf-8").strip()), source=str(path), unit=unit)
    except ValueError:
        return failed_reading(source=str(path), unit=unit, error="invalid_value")
    except OSError as exc:
        return failed_reading(source=str(path), unit=unit, error=f"read_error:{type(exc).__name__}:{exc}")


def _read_temperature(hwmon: Path | None, priorities: tuple[str, ...]) -> MetricReading:
    if hwmon is None:
        return failed_reading(source="gpu:hwmon", unit="celsius", error="hwmon_missing")
    candidates: list[tuple[str, Path]] = []
    for path in sorted(hwmon.glob("temp*_input")):
        label_path = hwmon / f"{path.name.split('_', 1)[0]}_label"
        label = (_read_text(label_path) or "unknown").lower()
        candidates.append((label, path))
    if not candidates:
        return failed_reading(source=f"{hwmon}/temp*_input", unit="celsius", error="source_missing")

    chosen = candidates[0]
    for wanted in priorities:
        match = next((candidate for candidate in candidates if candidate[0] == wanted), None)
        if match:
            chosen = match
            break
    raw = _read_float(chosen[1], "millicelsius")
    if not raw.valid or raw.raw_value is None:
        return failed_reading(source=str(chosen[1]), unit="celsius", error=raw.read_error or "read_error")
    return ok_reading(value=float(raw.raw_value) / 1000.0, source=f"{chosen[1]}:{chosen[0]}", unit="celsius")


def _read_power(hwmon: Path | None) -> MetricReading:
    if hwmon is None:
        return failed_reading(source="gpu:hwmon", unit="watt", error="hwmon_missing")
    for filename in ("power1_average", "power1_input"):
        raw = _read_float(hwmon / filename, "microwatt")
        if raw.valid and raw.raw_value is not None:
            return ok_reading(value=float(raw.raw_value) / 1_000_000.0, source=raw.source, unit="watt")
        if raw.read_error != "source_missing":
            return failed_reading(source=raw.source, unit="watt", error=raw.read_error or "read_error")
    return failed_reading(source=f"{hwmon}/power1_average", unit="watt", error="source_missing")


def _read_active_clock(path: Path) -> MetricReading:
    if not path.exists():
        return failed_reading(source=str(path), unit="mhz", error="source_missing")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return failed_reading(source=str(path), unit="mhz", error=f"read_error:{type(exc).__name__}:{exc}")
    line = next((line for line in lines if "*" in line), lines[-1] if lines else "")
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*([mMgG][hH][zZ])", line)
    if not match:
        return failed_reading(source=str(path), unit="mhz", error="invalid_value")
    value = float(match.group(1))
    if match.group(2).lower() == "ghz":
        value *= 1000.0
    return ok_reading(value=int(round(value)), source=str(path), unit="mhz")


def _read_first_int(hwmon: Path | None, pattern: str, unit: str) -> MetricReading:
    if hwmon is None:
        return failed_reading(source="gpu:hwmon", unit=unit, error="hwmon_missing")
    for path in sorted(hwmon.glob(pattern)):
        value = _read_int(path, unit)
        if value.valid or value.read_error != "source_missing":
            return value
    return failed_reading(source=f"{hwmon}/{pattern}", unit=unit, error="source_missing")


def _read_fan_percent(hwmon: Path | None) -> MetricReading:
    if hwmon is None:
        return failed_reading(source="gpu:hwmon", unit="percent", error="hwmon_missing")
    pwm = _read_int(hwmon / "pwm1", "raw")
    if not pwm.valid or pwm.raw_value is None:
        return failed_reading(source=str(hwmon / "pwm1"), unit="percent", error=pwm.read_error or "source_missing")
    pwm_max = _read_int(hwmon / "pwm1_max", "raw")
    maximum = float(pwm_max.raw_value) if pwm_max.valid and pwm_max.raw_value is not None else 255.0
    if maximum <= 0:
        return failed_reading(source=str(hwmon / "pwm1_max"), unit="percent", error="invalid_max")
    return ok_reading(value=float(pwm.raw_value) * 100.0 / maximum, source=str(hwmon / "pwm1"), unit="percent")
