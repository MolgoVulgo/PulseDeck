import json
import unittest
from urllib.request import urlopen

from pulsedeck_agent.http_server import AgentHTTPServer, PROTOCOL_NAME, WIRE_SCHEMA, build_wire_payload


class HttpTransportTests(unittest.TestCase):
    def test_wire_payload_does_not_alias_local_snapshot(self) -> None:
        snapshot = {"schema": 1, "ts": 123, "agent": {"id": "mini-server"}}
        payload = build_wire_payload(snapshot)
        self.assertEqual(payload["schema"], WIRE_SCHEMA)
        self.assertEqual(payload["protocol"], PROTOCOL_NAME)
        payload["snapshot"]["agent"]["id"] = "changed"  # type: ignore[index]
        self.assertEqual(snapshot["agent"]["id"], "mini-server")  # type: ignore[index]

    def test_http_snapshot_endpoint(self) -> None:
        snapshot = {"schema": 1, "ts": 123, "agent": {"id": "mini-server"}, "state": {"ok": True}}
        server = AgentHTTPServer("127.0.0.1", 0, lambda: snapshot)
        server.start()
        self.addCleanup(server.stop)
        port = server.bound_port
        self.assertIsNotNone(port)
        with urlopen(f"http://127.0.0.1:{port}/v1/snapshot", timeout=2) as response:
            payload = json.loads(response.read().decode("utf-8"))
        self.assertEqual(payload["schema"], 1)
        self.assertEqual(payload["protocol"], "pulsedeck-agent-http")
        self.assertEqual(payload["snapshot"]["agent"]["id"], "mini-server")


if __name__ == "__main__":
    unittest.main()
