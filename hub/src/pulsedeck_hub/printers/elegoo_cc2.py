"""Read-only ELEGOO Centauri Carbon 2 adapter.

The CC2 exposes a local MQTT 3.1.1 API. PulseDeck speaks that proprietary
protocol only on the Raspberry Pi and republishes normalized data on the hub
broker for the ESP32 clients.
"""

from __future__ import annotations

from dataclasses import dataclass
import base64
import binascii
import json
import logging
from pathlib import Path
import secrets
import struct
import threading
import time
from typing import TYPE_CHECKING, Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener
import zlib

import paho.mqtt.client as mqtt

from ..config import PrinterDeviceConfig, PrinterConfig
from ..mqtt.payloads import encode_payload
from ..mqtt.topics import printer_suffix

if TYPE_CHECKING:
    from ..mqtt.client import HubMQTTClient


LOG = logging.getLogger(__name__)
DRIVER = "elegoo_cc2"
MQTT_USERNAME = "elegoo"
APP_PING_INTERVAL = 30.0
MIN_REQUEST_INTERVAL = 2.0
PURGE_ZONE_Y_MM = 258.0
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SPEED_MODE_NAMES = {0: "silent", 1: "balanced", 2: "sport", 3: "ludicrous"}


class PrinterError(RuntimeError):
    """Sanitized printer protocol or transport error."""


class PrinterConnectionError(PrinterError):
    """The printer MQTT session is not ready."""


class PrinterRequestTimeout(PrinterError):
    """A CC2 API request did not receive a matching response in time."""


@dataclass(slots=True)
class _PendingRequest:
    event: threading.Event
    result: dict[str, Any] | None = None
    error: str | None = None


def _dict(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _number(value: object) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def _integer(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        value = value.strip()
        if value.isdigit():
            return int(value)
    return None


def _boolean(value: object) -> bool | None:
    if isinstance(value, bool):
        return value
    if value in (0, 1):
        return bool(value)
    return None


def _layer_progress(value: object) -> tuple[int | None, int | None]:
    if not isinstance(value, str) or "/" not in value:
        return None, None
    left, right = value.split("/", 1)
    return _integer(left), _integer(right)


def extract_job_identity(result: dict[str, Any]) -> tuple[str | None, int | None, int | None]:
    """Return active filename, current layer, and any total-layer hint from 1002."""
    print_status = _dict(result.get("print_status"))
    filename_raw = print_status.get("filename")
    filename = filename_raw if isinstance(filename_raw, str) and filename_raw else None
    current_layer = _integer(print_status.get("current_layer"))

    progress_value = result.get("layerProgress", print_status.get("layerProgress"))
    progress_current, progress_total = _layer_progress(progress_value)
    if current_layer is None:
        current_layer = progress_current
    return filename, current_layer, progress_total


def extract_total_layers(result: dict[str, Any]) -> int | None:
    """Read the known firmware variants returned by CC2 method 1046."""
    for key in ("layer", "TotalLayers", "total_layer"):
        value = _integer(result.get(key))
        if value is not None and value >= 0:
            return value
    return None


def _validate_png(data: bytes, *, max_pixels: int) -> tuple[int, int]:
    """Validate PNG structure/CRC and return its dimensions without decoding pixels."""
    if not data.startswith(PNG_SIGNATURE):
        raise PrinterError("thumbnail is not a PNG")

    offset = len(PNG_SIGNATURE)
    width = height = 0
    saw_ihdr = False
    saw_iend = False
    chunk_index = 0

    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        data_start = offset + 8
        data_end = data_start + length
        crc_end = data_end + 4
        if crc_end > len(data):
            raise PrinterError("thumbnail PNG is truncated")

        expected_crc = struct.unpack(">I", data[data_end:crc_end])[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(data[data_start:data_end], actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise PrinterError("thumbnail PNG has an invalid CRC")

        if chunk_index == 0:
            if chunk_type != b"IHDR" or length != 13:
                raise PrinterError("thumbnail PNG has no valid IHDR")
            width, height = struct.unpack(">II", data[data_start : data_start + 8])
            if width <= 0 or height <= 0 or width * height > max_pixels:
                raise PrinterError("thumbnail dimensions exceed the configured limit")
            saw_ihdr = True
        elif chunk_type == b"IHDR":
            raise PrinterError("thumbnail PNG contains multiple IHDR chunks")

        offset = crc_end
        chunk_index += 1
        if chunk_type == b"IEND":
            if length != 0:
                raise PrinterError("thumbnail PNG has an invalid IEND")
            saw_iend = True
            break

    if not saw_ihdr or not saw_iend or offset != len(data):
        raise PrinterError("thumbnail PNG structure is invalid")
    return width, height


def decode_thumbnail(
    value: object,
    *,
    max_base64_bytes: int,
    max_png_bytes: int,
    max_pixels: int,
) -> tuple[bytes, int, int]:
    """Decode method-1045 thumbnail data and enforce bounded PNG validation."""
    if not isinstance(value, str) or not value:
        raise PrinterError("thumbnail is missing")

    encoded = value.strip()
    if encoded.startswith("data:"):
        header, separator, body = encoded.partition(",")
        if not separator or header.lower() != "data:image/png;base64":
            raise PrinterError("thumbnail data URL is not PNG base64")
        encoded = body

    # The firmware normally emits one line. Tolerate whitespace while applying
    # the limit to both the received and normalized representation.
    if len(encoded.encode("ascii", errors="ignore")) > max_base64_bytes:
        raise PrinterError("thumbnail base64 exceeds the configured limit")
    encoded = "".join(encoded.split())
    if len(encoded) > max_base64_bytes:
        raise PrinterError("thumbnail base64 exceeds the configured limit")

    try:
        png = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise PrinterError("thumbnail contains invalid base64") from exc
    if len(png) > max_png_bytes:
        raise PrinterError("thumbnail PNG exceeds the configured limit")
    width, height = _validate_png(png, max_pixels=max_pixels)
    return png, width, height


def _state_name(result: dict[str, Any]) -> str:
    machine = _dict(result.get("machine_status"))
    move = _dict(result.get("gcode_move"))
    status = _integer(machine.get("status"))
    sub_status = _integer(machine.get("sub_status")) or 0
    progress = _integer(machine.get("progress"))
    head_y = _number(move.get("y"))

    if status in (0, 1):
        return "idle"
    if status == 2:
        if sub_status in (2801, 2802):
            return "homing"
        if sub_status in (2901, 2902):
            return "leveling"
        if sub_status == 2501:
            return "pausing"
        if sub_status in (2502, 2505):
            return "paused"
        if sub_status == 2401:
            return "resuming"
        if sub_status == 2503:
            return "stopping"
        if sub_status == 2504:
            return "stopped"
        if sub_status == 2077:
            return "completed"
        if (
            head_y is not None
            and float(head_y) >= PURGE_ZONE_Y_MM
            and (progress is None or progress < 100)
        ):
            return "filament_switching"
        if sub_status in (1045, 1096, 1405, 1906):
            return "preheating"
        return "printing"
    if status in (3, 4):
        if sub_status == 1136:
            return "filament_load_complete"
        if sub_status in (1144, 1145):
            return "filament_unloading"
        return "filament_switching"
    if status == 5:
        return "leveling"
    if status == 6:
        return "error"
    return "unknown"


def _fan(raw_fans: dict[str, Any], key: str) -> dict[str, object] | None:
    raw = _number(_dict(raw_fans.get(key)).get("speed"))
    if raw is None:
        return None
    value = float(raw)
    result: dict[str, object] = {"raw": raw}
    if 0.0 <= value <= 255.0:
        result["pct"] = round(value * 100.0 / 255.0)
    return result


def _temperature(block: dict[str, Any], *, include_target: bool = True) -> dict[str, object] | None:
    actual = _number(block.get("temperature"))
    target = _number(block.get("target")) if include_target else None
    if actual is None and target is None:
        return None
    result: dict[str, object] = {}
    if actual is not None:
        result["actual_c"] = actual
    if target is not None:
        result["target_c"] = target
    return result


def normalize_status(result: dict[str, Any], *, printer_id: str, timestamp: int | None = None) -> dict[str, object]:
    """Normalize method-1002 telemetry into the PulseDeck display contract."""
    ts = int(time.time()) if timestamp is None else int(timestamp)
    machine = _dict(result.get("machine_status"))
    move = _dict(result.get("gcode_move"))
    extruder = _dict(result.get("extruder"))
    bed = _dict(result.get("heater_bed"))
    chamber = _dict(result.get("ztemperature_sensor"))
    fans_raw = _dict(result.get("fans"))
    external = _dict(result.get("external_device"))
    led = _dict(result.get("led"))
    tool_head = _dict(result.get("tool_head"))

    speed_raw = _number(move.get("speed"))
    speed_mode_raw = _integer(move.get("speed_mode"))
    position: dict[str, object] = {}
    for axis in ("x", "y", "z"):
        value = _number(move.get(axis))
        if value is not None:
            position[axis] = value

    temperatures: dict[str, object] = {}
    for key, value in (
        ("nozzle", _temperature(extruder)),
        ("bed", _temperature(bed)),
        ("chamber", _temperature(chamber, include_target=False)),
    ):
        if value is not None:
            temperatures[key] = value

    fans: dict[str, object] = {}
    for target, source in (
        ("model", "fan"),
        ("auxiliary", "aux_fan"),
        ("chamber", "box_fan"),
        ("controller", "controller_fan"),
        ("heater", "heater_fan"),
    ):
        value = _fan(fans_raw, source)
        if value is not None:
            fans[target] = value

    normalized: dict[str, object] = {
        "schema": 1,
        "source": DRIVER,
        "printer_id": printer_id,
        "ts": ts,
        "state": _state_name(result),
        "raw_state": {
            "machine_status": _integer(machine.get("status")),
            "sub_status": _integer(machine.get("sub_status")),
            "reason_code": _integer(machine.get("sub_status_reason_code")),
            "exceptions": machine.get("exception_status") if isinstance(machine.get("exception_status"), list) else [],
        },
        "temperatures": temperatures,
        "fans": fans,
        "motion": {
            "speed_mm_s": None if speed_raw is None else round(float(speed_raw) / 60.0, 2),
            "speed_mode": SPEED_MODE_NAMES.get(speed_mode_raw),
            "speed_mode_raw": speed_mode_raw,
            "position_mm": position,
        },
        "filament_sensor": {
            "enabled": _boolean(extruder.get("filament_detect_enable")),
            "detected": _boolean(extruder.get("filament_detected")),
        },
        "light_on": _boolean(led.get("status")),
        "homed_axes": tool_head.get("homed_axes") if isinstance(tool_head.get("homed_axes"), str) else None,
        "external": {
            "camera": _boolean(external.get("camera")),
            "usb": _boolean(external.get("u_disk")),
            "type": external.get("type") if isinstance(external.get("type"), str) else None,
        },
    }
    return normalized


def normalize_job(
    result: dict[str, Any],
    *,
    printer_id: str,
    total_layers: int | None,
    thumbnail_available: bool,
    timestamp: int | None = None,
) -> dict[str, object]:
    """Normalize the current job using 1002 plus cached 1045/1046 metadata."""
    ts = int(time.time()) if timestamp is None else int(timestamp)
    print_status = _dict(result.get("print_status"))
    machine = _dict(result.get("machine_status"))
    filename, current_layer, total_hint = extract_job_identity(result)
    if total_layers is None:
        total_layers = total_hint

    elapsed = _integer(print_status.get("print_duration"))
    remaining = _integer(print_status.get("remaining_time_sec"))
    progress = _integer(machine.get("progress"))
    eta_ts = ts + remaining if remaining is not None and remaining > 0 else None

    return {
        "schema": 1,
        "source": DRIVER,
        "printer_id": printer_id,
        "ts": ts,
        "active": filename is not None,
        "state": _state_name(result),
        "filename": filename,
        "task_id": print_status.get("uuid") if isinstance(print_status.get("uuid"), str) else None,
        "progress_pct": progress,
        "current_layer": current_layer,
        "total_layers": total_layers,
        "elapsed_sec": elapsed,
        "remaining_sec": remaining,
        "eta_ts": eta_ts,
        "thumbnail_available": bool(filename and thumbnail_available),
    }




def fetch_cc2_serial(host: str, access_code: str, *, timeout: float = 5.0) -> str:
    """Discover the CC2 serial from its LAN-only HTTP API using the access code."""
    query = urlencode({"X-Token": access_code})
    request = Request(
        f"http://{host}/system/info?{query}",
        headers={"Accept": "application/json", "User-Agent": "PulseDeck/0.6"},
        method="GET",
    )
    opener = build_opener(ProxyHandler({}))
    try:
        with opener.open(request, timeout=timeout) as response:  # noqa: S310 - explicit LAN printer endpoint
            payload = response.read()
    except HTTPError as exc:
        if exc.code == 401:
            raise PrinterConnectionError("printer rejected the password/access code (HTTP 401)") from exc
        raise PrinterConnectionError(f"printer HTTP bootstrap failed: HTTP {exc.code}") from exc
    except (URLError, TimeoutError, OSError) as exc:
        raise PrinterConnectionError(
            "printer LAN API is unreachable; verify the IP/hostname and that LAN mode is enabled"
        ) from exc

    try:
        data = json.loads(payload)
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError) as exc:
        raise PrinterConnectionError("printer /system/info returned invalid JSON") from exc
    serial = _dict(_dict(data).get("system_info")).get("sn")
    if not isinstance(serial, str) or not serial.strip():
        raise PrinterConnectionError("printer /system/info did not return a serial number")
    serial = serial.strip()
    if any(ch in serial for ch in "/#+") or any(ch.isspace() for ch in serial):
        raise PrinterConnectionError("printer returned a serial number unsafe for MQTT topics")
    return serial


class ElegooCC2Client:
    """Small synchronous request/response client over the CC2 local MQTT broker."""

    def __init__(self, device: PrinterDeviceConfig, access_code: str, *, request_timeout: int) -> None:
        self.device = device
        self.access_code = access_code
        self.request_timeout = float(request_timeout)
        self._serial_number: str | None = None
        self._mqtt_loop_started = False
        self.client_id = f"1_PC_{secrets.randbelow(90_000_000) + 10_000_000}"
        self.request_id_prefix = f"{self.client_id}_req"
        self._request_counter = 0
        self._pending: dict[int, _PendingRequest] = {}
        self._pending_lock = threading.Lock()
        self._send_lock = threading.Lock()
        self._last_request_at = 0.0
        self._stop = threading.Event()
        self.connected = threading.Event()
        self.registered = threading.Event()
        self._last_connect_error: str | None = None
        self._last_registration_error: str | None = None

        self.client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=self.client_id,
            protocol=mqtt.MQTTv311,
            clean_session=True,
        )
        self.client.username_pw_set(MQTT_USERNAME, access_code)
        self.client.on_connect = self._on_connect
        self.client.on_connect_fail = self._on_connect_fail
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message
        self.client.reconnect_delay_set(
            min_delay=device.reconnect_min_delay,
            max_delay=device.reconnect_max_delay,
        )
        self.client.enable_logger(logging.getLogger(f"paho.mqtt.printer.{device.id}"))
        self._bootstrap_thread = threading.Thread(
            target=self._bootstrap_loop,
            name=f"printer-{device.id}-bootstrap",
            daemon=True,
        )
        self._ping_thread = threading.Thread(
            target=self._ping_loop,
            name=f"printer-{device.id}-ping",
            daemon=True,
        )

    @property
    def serial_number(self) -> str | None:
        return self._serial_number

    def _require_serial(self) -> str:
        if self._serial_number is None:
            raise PrinterConnectionError("printer serial has not been discovered yet")
        return self._serial_number

    @property
    def request_topic(self) -> str:
        return f"elegoo/{self._require_serial()}/{self.client_id}/api_request"

    @property
    def response_topic(self) -> str:
        return f"elegoo/{self._require_serial()}/{self.client_id}/api_response"

    @property
    def register_topic(self) -> str:
        return f"elegoo/{self._require_serial()}/api_register"

    @property
    def register_response_topic(self) -> str:
        return f"elegoo/{self._require_serial()}/{self.request_id_prefix}/register_response"

    def start(self) -> None:
        self._bootstrap_thread.start()
        self._ping_thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._fail_pending("connection stopped")
        if self._mqtt_loop_started:
            try:
                self.client.disconnect()
            finally:
                self.client.loop_stop()
        if self._bootstrap_thread.is_alive():
            self._bootstrap_thread.join(timeout=1.0)
        if self._ping_thread.is_alive():
            self._ping_thread.join(timeout=1.0)

    def _bootstrap_loop(self) -> None:
        retry_delay = float(self.device.reconnect_min_delay)
        while not self._stop.is_set():
            try:
                serial = fetch_cc2_serial(
                    self.device.host,
                    self.access_code,
                    timeout=min(max(self.request_timeout, 2.0), 10.0),
                )
                self._serial_number = serial
                self._last_connect_error = None
                # Paho 2.x connect_async() configures the asynchronous connection and
                # deliberately returns None. Connection success/failure is reported later
                # through on_connect/on_connect_fail once the network loop is running.
                self.client.connect_async(self.device.host, self.device.port, keepalive=30)
                loop_result = self.client.loop_start()
                if loop_result != mqtt.MQTT_ERR_SUCCESS:
                    raise PrinterConnectionError(f"MQTT network loop start failed: rc={loop_result}")
                self._mqtt_loop_started = True
                LOG.info(
                    "Printer %s LAN bootstrap ready at %s (serial=%s)",
                    self.device.id,
                    self.device.host,
                    serial,
                )
                return
            except PrinterError as exc:
                self._last_connect_error = str(exc)
                self.connected.clear()
                self.registered.clear()
                LOG.warning("Printer %s LAN bootstrap failed: %s", self.device.id, exc)
                if self._stop.wait(retry_delay):
                    return
                retry_delay = min(
                    float(self.device.reconnect_max_delay),
                    max(retry_delay * 2.0, 1.0),
                )

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:  # noqa: ANN001
        if getattr(reason_code, "is_failure", False):
            self._last_connect_error = str(reason_code)
            self.connected.clear()
            self.registered.clear()
            return
        self._last_connect_error = None
        self._last_registration_error = None
        self.registered.clear()
        serial = self._require_serial()
        result, _mid = client.subscribe(f"elegoo/{serial}/#", qos=0)
        if result != mqtt.MQTT_ERR_SUCCESS:
            self._last_registration_error = f"subscribe rc={result}"
            self.connected.clear()
            return
        self.connected.set()
        self._publish_register()
        LOG.info("Printer %s MQTT connected to %s:%s", self.device.id, self.device.host, self.device.port)

    def _on_connect_fail(self, client, userdata) -> None:  # noqa: ANN001
        self.connected.clear()
        self.registered.clear()
        self._last_connect_error = "connection attempt failed"

    def _on_disconnect(self, client, userdata, disconnect_flags, reason_code, properties) -> None:  # noqa: ANN001
        self.connected.clear()
        self.registered.clear()
        self._fail_pending(f"MQTT disconnected: {reason_code}")
        if not self._stop.is_set():
            LOG.warning("Printer %s MQTT disconnected: %s", self.device.id, reason_code)

    def _on_message(self, client, userdata, message: mqtt.MQTTMessage) -> None:  # noqa: ANN001
        try:
            data = json.loads(message.payload)
        except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
            return
        if not isinstance(data, dict):
            return

        if message.topic == self.register_response_topic:
            if data.get("error") == "ok":
                self._last_registration_error = None
                self.registered.set()
                LOG.info("Printer %s API registration ready", self.device.id)
            else:
                self._last_registration_error = "registration rejected"
                self.registered.clear()
            return

        # The wildcard subscription also sees other clients. Correlate only
        # responses published on this client's response topic.
        if message.topic != self.response_topic:
            return
        if data.get("method") in (6000, 6008) or data.get("type") == "PONG":
            return
        request_id = data.get("id")
        if not isinstance(request_id, int):
            return
        result = data.get("result")
        if not isinstance(result, dict):
            result = {}
        with self._pending_lock:
            pending = self._pending.get(request_id)
            if pending is not None:
                pending.result = result
                pending.event.set()

    def _publish_register(self) -> None:
        payload = encode_payload({"client_id": self.client_id, "request_id": self.request_id_prefix})
        info = self.client.publish(self.register_topic, payload=payload, qos=0, retain=False)
        if info.rc != mqtt.MQTT_ERR_SUCCESS:
            self._last_registration_error = f"register publish rc={info.rc}"

    def _ping_loop(self) -> None:
        while not self._stop.wait(APP_PING_INTERVAL):
            if not (self.connected.is_set() and self.registered.is_set()):
                continue
            # Serialize PING with API calls so the firmware never receives a
            # keepalive immediately adjacent to the request burst.
            with self._send_lock:
                delay = MIN_REQUEST_INTERVAL - (time.monotonic() - self._last_request_at)
                if delay > 0 and self._stop.wait(delay):
                    return
                info = self.client.publish(
                    self.request_topic,
                    payload='{"type":"PING"}',
                    qos=0,
                    retain=False,
                )
                self._last_request_at = time.monotonic()
            if info.rc != mqtt.MQTT_ERR_SUCCESS:
                LOG.debug(
                    "Printer %s application PING publish failed: rc=%s",
                    self.device.id,
                    info.rc,
                )

    def _wait_ready(self, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        remaining = max(0.0, deadline - time.monotonic())
        if not self.connected.wait(remaining):
            detail = self._last_connect_error or "MQTT connection not ready"
            raise PrinterConnectionError(detail)
        remaining = max(0.0, deadline - time.monotonic())
        if not self.registered.wait(remaining):
            detail = self._last_registration_error or "printer API registration not ready"
            raise PrinterConnectionError(detail)

    def _fail_pending(self, error: str) -> None:
        with self._pending_lock:
            for pending in self._pending.values():
                pending.error = error
                pending.event.set()

    def request(self, method: int, params: dict[str, object] | None = None) -> dict[str, Any]:
        """Publish one JSON-RPC-style CC2 request and wait for the same id."""
        self._wait_ready(self.request_timeout)
        params = {} if params is None else params

        with self._send_lock:
            delay = MIN_REQUEST_INTERVAL - (time.monotonic() - self._last_request_at)
            if delay > 0:
                if self._stop.wait(delay):
                    raise PrinterConnectionError("connection stopped")
            self._request_counter += 1
            request_id = self._request_counter
            pending = _PendingRequest(event=threading.Event())
            with self._pending_lock:
                self._pending[request_id] = pending

            body = encode_payload({"id": request_id, "method": method, "params": params})
            info = self.client.publish(self.request_topic, payload=body, qos=0, retain=False)
            self._last_request_at = time.monotonic()
            if info.rc != mqtt.MQTT_ERR_SUCCESS:
                with self._pending_lock:
                    self._pending.pop(request_id, None)
                raise PrinterConnectionError(f"request publish failed: rc={info.rc}")

        if not pending.event.wait(self.request_timeout):
            with self._pending_lock:
                self._pending.pop(request_id, None)
            # A CC2 registration can expire while MQTT remains connected.
            # Re-register so the next request can recover without a broker reconnect.
            self.registered.clear()
            if self.connected.is_set():
                self._publish_register()
            raise PrinterRequestTimeout(f"method {method} timed out")

        with self._pending_lock:
            self._pending.pop(request_id, None)
        if pending.error:
            raise PrinterConnectionError(pending.error)
        result = pending.result or {}
        error_code = _integer(result.get("error_code"))
        if error_code not in (None, 0):
            raise PrinterError(f"method {method} returned error_code={error_code}")
        return result


class ElegooCC2Adapter:
    """One CC2 source instance, including collection and PulseDeck publication."""

    def __init__(self, device: PrinterDeviceConfig, config: PrinterConfig, mqtt_client: "HubMQTTClient") -> None:
        self.device = device
        self.config = config
        self.mqtt = mqtt_client
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name=f"printer-{device.id}",
            daemon=True,
        )
        self._client: ElegooCC2Client | None = None
        self._active_filename: str | None = None
        self._metadata_filename: str | None = None
        self._total_layers: int | None = None
        self._thumbnail_available = False
        self._thumbnail_png: bytes | None = None
        self._thumbnail_lock = threading.Lock()
        self._last_success: int | None = None
        self._availability_state: str | None = None

    def _topic(self, leaf: str) -> str:
        return printer_suffix(self.device.id, leaf)

    def start(self) -> None:
        access_code = self._read_secret(self.device.access_code_file)
        self._client = ElegooCC2Client(
            self.device,
            access_code,
            request_timeout=self.config.request_timeout,
        )
        self._client.start()
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._client is not None:
            self._client.stop()
        if self._thread.is_alive():
            self._thread.join(timeout=float(self.config.request_timeout) + 2.0)
        self._publish_availability("offline", reason="collector_stopped", force=True)

    @staticmethod
    def _read_secret(path: Path) -> str:
        try:
            value = path.read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise PrinterError(f"cannot read access code file {path}") from exc
        if not value:
            raise PrinterError(f"access code file {path} is empty")
        return value

    def _publish_availability(self, state: str, *, reason: str | None = None, force: bool = False) -> None:
        if not force and self._availability_state == state:
            return
        payload: dict[str, object] = {
            "schema": 1,
            "source": DRIVER,
            "printer_id": self.device.id,
            "state": state,
            "ts": int(time.time()),
        }
        if self._last_success is not None:
            payload["last_success"] = self._last_success
        if self._client is not None and self._client.serial_number:
            payload["serial"] = self._client.serial_number
        if reason:
            payload["reason"] = reason
        if self.mqtt.publish_retained(self._topic("availability"), encode_payload(payload)):
            self._availability_state = state

    def _publish_snapshot(self, result: dict[str, Any]) -> None:
        timestamp = int(time.time())
        status = normalize_status(result, printer_id=self.device.id, timestamp=timestamp)
        job = normalize_job(
            result,
            printer_id=self.device.id,
            total_layers=self._total_layers,
            thumbnail_available=self._thumbnail_available,
            timestamp=timestamp,
        )
        self.mqtt.publish_retained(self._topic("status"), encode_payload(status))
        self.mqtt.publish_retained(self._topic("job"), encode_payload(job))

    def thumbnail_png(self) -> bytes | None:
        """Return the current validated PNG cached for the Admin view."""
        with self._thumbnail_lock:
            return self._thumbnail_png

    def _clear_thumbnail(self) -> None:
        self._thumbnail_available = False
        with self._thumbnail_lock:
            self._thumbnail_png = None
        self.mqtt.clear_retained(self._topic("thumbnail"))

    def _request_thumbnail(self, filename: str) -> tuple[bytes, int, int] | None:
        assert self._client is not None
        try:
            result = self._client.request(
                1045,
                {"storage_media": "local", "file_name": filename},
            )
            return decode_thumbnail(
                result.get("thumbnail"),
                max_base64_bytes=self.config.thumbnail_max_base64_bytes,
                max_png_bytes=self.config.thumbnail_max_png_bytes,
                max_pixels=self.config.thumbnail_max_pixels,
            )
        except PrinterError as exc:
            LOG.warning("Printer %s thumbnail unavailable: %s", self.device.id, exc)
            return None

    def _request_total_layers(self, filename: str) -> int | None:
        assert self._client is not None
        try:
            result = self._client.request(
                1046,
                {"storage_media": "local", "filename": filename},
            )
        except PrinterError as exc:
            LOG.warning("Printer %s total layers unavailable: %s", self.device.id, exc)
            return None
        return extract_total_layers(result)

    def _enrich_new_job(self, filename: str, total_hint: int | None) -> dict[str, Any] | None:
        """Fetch immutable job metadata, then verify the active filename again."""
        assert self._client is not None
        thumbnail = self._request_thumbnail(filename)
        total_layers = total_hint if total_hint is not None else self._request_total_layers(filename)

        # Verify against a fresh status response before committing metadata.
        # This rejects a late 1045/1046 response if a different job started.
        try:
            verify = self._client.request(1002, {})
        except PrinterError as exc:
            LOG.warning("Printer %s job metadata verification failed: %s", self.device.id, exc)
            return None
        verify_filename, _current, verify_total_hint = extract_job_identity(verify)
        if verify_filename != filename:
            LOG.info(
                "Printer %s job changed during metadata fetch (%r -> %r); ignoring stale metadata",
                self.device.id,
                filename,
                verify_filename,
            )
            return verify

        if total_layers is None:
            total_layers = verify_total_hint
        self._total_layers = total_layers
        if thumbnail is not None:
            png, width, height = thumbnail
            if self.mqtt.publish_retained_binary(self._topic("thumbnail"), png, qos=1):
                self._thumbnail_available = True
                with self._thumbnail_lock:
                    self._thumbnail_png = png
                LOG.info(
                    "Printer %s thumbnail cached: %s (%dx%d, %d bytes)",
                    self.device.id,
                    filename,
                    width,
                    height,
                    len(png),
                )
        return verify

    def _handle_status(self, result: dict[str, Any]) -> dict[str, Any]:
        filename, _current_layer, total_hint = extract_job_identity(result)
        if filename != self._active_filename:
            old_filename = self._active_filename
            self._active_filename = filename
            self._metadata_filename = None
            self._total_layers = total_hint
            self._clear_thumbnail()
            LOG.info("Printer %s job changed: %r -> %r", self.device.id, old_filename, filename)
            self._publish_snapshot(result)
        elif self._total_layers is None and total_hint is not None:
            self._total_layers = total_hint

        if filename and self._metadata_filename != filename:
            verified = self._enrich_new_job(filename, total_hint)
            if verified is not None:
                verified_filename, _current, verified_hint = extract_job_identity(verified)
                if verified_filename == filename:
                    self._metadata_filename = filename
                    result = verified
                else:
                    # Do not mark the newer job as enriched. Update the active
                    # identity and let the next status cycle fetch its own
                    # immutable metadata.
                    self._active_filename = verified_filename
                    self._metadata_filename = None
                    self._total_layers = verified_hint
                    self._clear_thumbnail()
                    result = verified
        return result

    def _run(self) -> None:
        assert self._client is not None
        self._publish_availability("offline", reason="starting", force=True)
        retry_delay = float(self.device.reconnect_min_delay)

        while not self._stop.is_set():
            if not self.mqtt.connected.wait(timeout=1.0):
                continue
            started = time.monotonic()
            try:
                result = self._client.request(1002, {})
                result = self._handle_status(result)
                self._last_success = int(time.time())
                self._publish_snapshot(result)
                self._publish_availability("online")
                retry_delay = float(self.device.reconnect_min_delay)
            except PrinterError as exc:
                LOG.warning("Printer %s unavailable: %s", self.device.id, exc)
                self._publish_availability("offline", reason=str(exc))
                self._stop.wait(retry_delay)
                retry_delay = min(float(self.device.reconnect_max_delay), max(retry_delay * 2.0, 1.0))
                continue

            elapsed = time.monotonic() - started
            self._stop.wait(max(0.2, float(self.config.poll_interval) - elapsed))
