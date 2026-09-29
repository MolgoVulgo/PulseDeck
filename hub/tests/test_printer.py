from __future__ import annotations

import base64
import json
from pathlib import Path
import struct
import zlib

import pytest

from pulsedeck_hub.config import load_config
from pulsedeck_hub.printers.elegoo_cc2 import (
    PrinterError,
    decode_thumbnail,
    extract_job_identity,
    extract_total_layers,
    normalize_job,
    normalize_status,
)


def _chunk(kind: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(kind)
    crc = zlib.crc32(data, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)


def _png(width: int = 2, height: int = 2) -> bytes:
    signature = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    rows = b"".join(b"\x00" + (b"\x00\x00\x00\xff" * width) for _ in range(height))
    return signature + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", zlib.compress(rows)) + _chunk(b"IEND", b"")


def _status_payload() -> dict[str, object]:
    return {
        "gcode_move": {"speed": 3000, "speed_mode": 1, "x": 10.0, "y": 20.0, "z": 3.0},
        "extruder": {
            "temperature": 215.2,
            "target": 220,
            "filament_detect_enable": 1,
            "filament_detected": 1,
        },
        "heater_bed": {"temperature": 59.5, "target": 60},
        "ztemperature_sensor": {"temperature": 31.0},
        "fans": {
            "fan": {"speed": 255},
            "aux_fan": {"speed": 128},
            "box_fan": {"speed": 0},
            "controller_fan": {"speed": 64},
            "heater_fan": {"speed": 200},
        },
        "machine_status": {
            "status": 2,
            "sub_status": 0,
            "sub_status_reason_code": 0,
            "exception_status": [],
            "progress": 13,
        },
        "print_status": {
            "filename": "piece.gcode",
            "current_layer": 42,
            "print_duration": 1200,
            "remaining_time_sec": 3600,
            "uuid": "job-1",
        },
        "led": {"status": 1},
        "tool_head": {"homed_axes": "xyz"},
        "external_device": {"camera": True, "u_disk": False, "type": "0303"},
    }


def test_thumbnail_accepts_raw_base64_and_data_url() -> None:
    png = _png()
    encoded = base64.b64encode(png).decode("ascii")
    for value in (encoded, f"data:image/png;base64,{encoded}"):
        decoded, width, height = decode_thumbnail(
            value,
            max_base64_bytes=100_000,
            max_png_bytes=100_000,
            max_pixels=100_000,
        )
        assert decoded == png
        assert (width, height) == (2, 2)


def test_thumbnail_rejects_invalid_png_crc() -> None:
    png = bytearray(_png())
    png[-1] ^= 0x01
    encoded = base64.b64encode(png).decode("ascii")
    with pytest.raises(PrinterError, match="CRC"):
        decode_thumbnail(
            encoded,
            max_base64_bytes=100_000,
            max_png_bytes=100_000,
            max_pixels=100_000,
        )


def test_layer_sources_are_normalized() -> None:
    result = _status_payload()
    result["layerProgress"] = "42/318"
    assert extract_job_identity(result) == ("piece.gcode", 42, 318)
    assert extract_total_layers({"layer": 318}) == 318
    assert extract_total_layers({"TotalLayers": "318"}) == 318
    assert extract_total_layers({"total_layer": 318.0}) == 318


def test_status_and_job_payloads_are_display_ready() -> None:
    result = _status_payload()
    status = normalize_status(result, printer_id="cc2-main", timestamp=1_800_000_000)
    job = normalize_job(
        result,
        printer_id="cc2-main",
        total_layers=318,
        thumbnail_available=True,
        timestamp=1_800_000_000,
    )

    assert status["state"] == "printing"
    assert status["motion"]["speed_mm_s"] == 50.0
    assert status["motion"]["speed_mode"] == "balanced"
    assert status["fans"]["model"]["pct"] == 100
    assert status["external"]["camera"] is True
    assert job["filename"] == "piece.gcode"
    assert job["current_layer"] == 42
    assert job["total_layers"] == 318
    assert job["eta_ts"] == 1_800_003_600
    assert job["thumbnail_available"] is True


def test_multi_printer_configuration_loads(tmp_path: Path) -> None:
    secret = tmp_path / "cc2.code"
    secret.write_text("secret", encoding="utf-8")
    path = tmp_path / "pulsedeck.toml"
    path.write_text(
        f'''[mqtt]\nhost = "192.168.0.250"\n\n[collectors.printer]\nenabled = true\npoll_interval = 5\n\n[[collectors.printer.devices]]\nid = "cc2-main"\ndriver = "elegoo_cc2"\nhost = "192.168.0.123"\nserial = "ELEGOO123456"\naccess_code_file = {json.dumps(str(secret))}\n''',
        encoding="utf-8",
    )
    config = load_config(path)
    assert config.printer.enabled is True
    assert len(config.printer.devices) == 1
    assert config.printer.devices[0].id == "cc2-main"
    assert config.printer.devices[0].port == 1883


def test_duplicate_printer_ids_are_rejected(tmp_path: Path) -> None:
    path = tmp_path / "pulsedeck.toml"
    path.write_text(
        '''[mqtt]\nhost = "192.168.0.250"\n\n[collectors.printer]\nenabled = true\n\n[[collectors.printer.devices]]\nid = "same"\nhost = "one"\nserial = "A"\naccess_code_file = "/tmp/a"\n\n[[collectors.printer.devices]]\nid = "same"\nhost = "two"\nserial = "B"\naccess_code_file = "/tmp/b"\n''',
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="duplicate printer id"):
        load_config(path)

class _FakeHubMQTT:
    def publish_retained(self, suffix: str, payload: str, *, qos: int = 1) -> bool:
        return True

    def publish_retained_binary(self, suffix: str, payload: bytes, *, qos: int = 1) -> bool:
        return True

    def clear_retained(self, suffix: str, *, qos: int = 1) -> bool:
        return True


def test_job_metadata_is_retried_until_verified(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    from pulsedeck_hub.config import PrinterConfig, PrinterDeviceConfig
    from pulsedeck_hub.printers.elegoo_cc2 import ElegooCC2Adapter

    device = PrinterDeviceConfig(
        id="cc2-main",
        driver="elegoo_cc2",
        host="printer.local",
        serial="ELEGOO123",
        access_code_file=tmp_path / "code",
    )
    adapter = ElegooCC2Adapter(device, PrinterConfig(enabled=True, devices=(device,)), _FakeHubMQTT())
    first = _status_payload()

    monkeypatch.setattr(adapter, "_enrich_new_job", lambda filename, total_hint: None)
    adapter._handle_status(first)
    assert adapter._active_filename == "piece.gcode"
    assert adapter._metadata_filename is None

    verified = _status_payload()
    monkeypatch.setattr(adapter, "_enrich_new_job", lambda filename, total_hint: verified)
    adapter._handle_status(first)
    assert adapter._metadata_filename == "piece.gcode"


def test_stale_metadata_response_does_not_mark_new_job_enriched(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    from pulsedeck_hub.config import PrinterConfig, PrinterDeviceConfig
    from pulsedeck_hub.printers.elegoo_cc2 import ElegooCC2Adapter

    device = PrinterDeviceConfig(
        id="cc2-main",
        driver="elegoo_cc2",
        host="printer.local",
        serial="ELEGOO123",
        access_code_file=tmp_path / "code",
    )
    adapter = ElegooCC2Adapter(device, PrinterConfig(enabled=True, devices=(device,)), _FakeHubMQTT())
    old_job = _status_payload()
    new_job = _status_payload()
    new_job["print_status"] = dict(new_job["print_status"], filename="next.gcode", current_layer=1)

    monkeypatch.setattr(adapter, "_enrich_new_job", lambda filename, total_hint: new_job)
    returned = adapter._handle_status(old_job)
    assert extract_job_identity(returned)[0] == "next.gcode"
    assert adapter._active_filename == "next.gcode"
    assert adapter._metadata_filename is None
