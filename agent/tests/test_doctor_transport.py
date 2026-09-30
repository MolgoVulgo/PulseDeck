import time
import unittest

from pulsedeck_agent.cli import _transport_check
from pulsedeck_agent.config import AgentConfig
from pulsedeck_agent.http_server import AgentHTTPServer


def _config(*, enabled: bool, port: int, listen: str = "0.0.0.0") -> AgentConfig:
    return AgentConfig(
        agent_id="mini-server",
        name="Mini Server",
        network_interface="eth0",
        gpu_enabled=False,
        gpu_pci_slot=None,
        gpu_temperature_labels=("unknown",),
        sample_interval_s=1.0,
        transport_enabled=enabled,
        transport_listen=listen,
        transport_port=port,
    )


def _snapshot(agent_id: str = "mini-server") -> dict[str, object]:
    return {
        "schema": 1,
        "ts": int(time.time()),
        "agent": {"id": agent_id, "name": "Mini Server"},
        "capabilities": ["cpu", "memory", "network"],
        "state": {"ok": True},
    }


class DoctorTransportTests(unittest.TestCase):
    def test_disabled_transport_is_not_a_failure(self) -> None:
        ok, text = _transport_check(_config(enabled=False, port=8765), "mini-server", 1.0)
        self.assertTrue(ok)
        self.assertEqual(text, "disabled")

    def test_enabled_transport_checks_health_and_snapshot(self) -> None:
        server = AgentHTTPServer("127.0.0.1", 0, _snapshot)
        server.start()
        self.addCleanup(server.stop)
        port = server.bound_port
        self.assertIsNotNone(port)

        # A wildcard bind is probed through loopback by doctor; 0.0.0.0 is not
        # used as a connection destination.
        ok, text = _transport_check(_config(enabled=True, port=int(port)), "mini-server", 1.0)
        self.assertTrue(ok, text)
        self.assertIn("127.0.0.1", text)
        self.assertIn("health + snapshot", text)

    def test_enabled_transport_rejects_wrong_agent_snapshot(self) -> None:
        server = AgentHTTPServer("127.0.0.1", 0, lambda: _snapshot("other-agent"))
        server.start()
        self.addCleanup(server.stop)
        port = server.bound_port
        self.assertIsNotNone(port)

        ok, text = _transport_check(_config(enabled=True, port=int(port)), "mini-server", 1.0)
        self.assertFalse(ok)
        self.assertIn("stale/invalid /v1/snapshot", text)

    def test_enabled_transport_rejects_missing_mandatory_capability(self) -> None:
        snapshot = _snapshot()
        snapshot["capabilities"] = ["cpu", "memory"]
        server = AgentHTTPServer("127.0.0.1", 0, lambda: snapshot)
        server.start()
        self.addCleanup(server.stop)
        port = server.bound_port
        self.assertIsNotNone(port)

        ok, text = _transport_check(_config(enabled=True, port=int(port)), "mini-server", 1.0)
        self.assertFalse(ok)
        self.assertIn("stale/invalid /v1/snapshot", text)

    def test_enabled_transport_fails_when_listener_is_missing(self) -> None:
        # Reserve an ephemeral port, stop the server, then probe the now-closed port.
        server = AgentHTTPServer("127.0.0.1", 0, _snapshot)
        server.start()
        port = server.bound_port
        self.assertIsNotNone(port)
        server.stop()

        ok, text = _transport_check(_config(enabled=True, port=int(port)), "mini-server", 1.0)
        self.assertFalse(ok)
        self.assertIn("FAIL", text)


if __name__ == "__main__":
    unittest.main()
