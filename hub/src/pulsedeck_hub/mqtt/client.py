"""Persistent MQTT connection for the PulseDeck hub."""

from __future__ import annotations

import logging
import threading
import time

import paho.mqtt.client as mqtt

from ..config import MQTTConfig
from .payloads import availability_payload


LOG = logging.getLogger(__name__)


class HubMQTTClient:
    def __init__(self, config: MQTTConfig) -> None:
        self.config = config
        self.session_started = int(time.time())
        self.connected = threading.Event()
        self._retained_lock = threading.Lock()
        self._retained_publications: dict[str, dict[str, object]] = {}
        self.client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=config.client_id,
            protocol=mqtt.MQTTv311,
            clean_session=True,
        )
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_connect_fail = self._on_connect_fail
        self.client.reconnect_delay_set(
            min_delay=config.reconnect_min_delay,
            max_delay=config.reconnect_max_delay,
        )
        self.client.enable_logger(logging.getLogger("paho.mqtt"))

        # A Last Will cannot know the future disconnect timestamp. `ts` therefore
        # records when the Will was prepared and `ts_kind` makes that explicit.
        will = availability_payload(
            "offline",
            session_started=self.session_started,
            reason="connection_lost",
            timestamp=self.session_started,
            timestamp_kind="will_created",
        )
        self.client.will_set(
            config.availability_topic,
            payload=will,
            qos=1,
            retain=True,
        )

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:  # noqa: ANN001
        if reason_code.is_failure:
            LOG.error("MQTT connection refused: %s", reason_code)
            self.connected.clear()
            return
        self.connected.set()
        payload = availability_payload(
            "online",
            session_started=self.session_started,
        )
        info = client.publish(
            self.config.availability_topic,
            payload=payload,
            qos=1,
            retain=True,
        )
        if info.rc != mqtt.MQTT_ERR_SUCCESS:
            LOG.error("Unable to publish online availability: rc=%s", info.rc)
        LOG.info(
            "MQTT connected to %s:%s; availability=%s",
            self.config.host,
            self.config.port,
            self.config.availability_topic,
        )

    def _on_connect_fail(self, client, userdata) -> None:  # noqa: ANN001
        self.connected.clear()
        LOG.warning("MQTT connection attempt failed; automatic retry remains active")

    def _on_disconnect(self, client, userdata, disconnect_flags, reason_code, properties) -> None:  # noqa: ANN001
        self.connected.clear()
        if reason_code.is_failure:
            LOG.warning("MQTT disconnected unexpectedly: %s", reason_code)
        else:
            LOG.info("MQTT disconnected")

    def start(self) -> None:
        LOG.info("Starting MQTT client %s", self.config.client_id)
        self.client.connect_async(
            self.config.host,
            self.config.port,
            self.config.keepalive,
        )
        self.client.loop_start()


    def publish_retained(self, suffix: str, payload: str, *, qos: int = 1) -> bool:
        """Publish a retained application payload below the configured namespace."""
        if not self.connected.is_set():
            return False
        topic_name = f"{self.config.namespace.rstrip('/')}/{suffix.lstrip('/')}"
        info = self.client.publish(topic_name, payload=payload, qos=qos, retain=True)
        if info.rc != mqtt.MQTT_ERR_SUCCESS:
            LOG.warning("MQTT publish failed for %s: rc=%s", topic_name, info.rc)
            return False
        try:
            info.wait_for_publish(timeout=2.0)
        except RuntimeError:
            LOG.warning("MQTT publish confirmation timed out for %s", topic_name)
            return False
        if not info.is_published():
            return False
        normalized_suffix = suffix.lstrip("/")
        with self._retained_lock:
            self._retained_publications[normalized_suffix] = {
                "topic": topic_name,
                "payload": payload,
                "published_at": int(time.time()),
                "qos": qos,
            }
        return True

    def retained_snapshot(self, prefix: str | None = None) -> dict[str, dict[str, object]]:
        """Return the last retained publications confirmed by this hub process."""
        normalized_prefix = prefix.strip("/") if prefix else None
        with self._retained_lock:
            return {
                suffix: dict(entry)
                for suffix, entry in self._retained_publications.items()
                if normalized_prefix is None
                or suffix == normalized_prefix
                or suffix.startswith(normalized_prefix + "/")
            }

    def stop(self) -> None:
        if self.connected.is_set():
            payload = availability_payload(
                "offline",
                session_started=self.session_started,
                reason="graceful_shutdown",
            )
            info = self.client.publish(
                self.config.availability_topic,
                payload=payload,
                qos=1,
                retain=True,
            )
            try:
                info.wait_for_publish(timeout=2.0)
            except RuntimeError:
                LOG.warning("MQTT offline availability could not be confirmed before shutdown")
        self.client.disconnect()
        self.client.loop_stop()
