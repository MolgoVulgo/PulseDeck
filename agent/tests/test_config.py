from pathlib import Path
import tempfile
import unittest

from pulsedeck_agent.config import ConfigError, load_config


class ConfigTests(unittest.TestCase):
    def _write(self, text: str) -> Path:
        tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".yml", delete=False)
        tmp.write(text)
        tmp.close()
        self.addCleanup(lambda: Path(tmp.name).unlink(missing_ok=True))
        return Path(tmp.name)

    def test_minimal_config_defaults(self) -> None:
        cfg = load_config(self._write("{}\n"))
        self.assertTrue(cfg.agent_id)
        self.assertEqual(cfg.network_interface, "auto")
        self.assertFalse(cfg.gpu_enabled)
        self.assertEqual(cfg.sample_interval_s, 1.0)
        self.assertFalse(cfg.transport_enabled)
        self.assertEqual(cfg.transport_listen, "0.0.0.0")
        self.assertEqual(cfg.transport_port, 8765)

    def test_gpu_config(self) -> None:
        cfg = load_config(self._write("""
agent:
  id: gaming-pc
  name: Gaming PC
collectors:
  network:
    interface: enp1s0
  gpu:
    enabled: true
    pci_slot: "0000:03:00.0"
runtime:
  sample_interval_s: 2
"""))
        self.assertEqual(cfg.agent_id, "gaming-pc")
        self.assertEqual(cfg.network_interface, "enp1s0")
        self.assertTrue(cfg.gpu_enabled)
        self.assertEqual(cfg.gpu_pci_slot, "0000:03:00.0")

    def test_http_transport_config(self) -> None:
        cfg = load_config(self._write("""
transport:
  enabled: true
  listen: 192.168.0.10
  port: 9876
"""))
        self.assertTrue(cfg.transport_enabled)
        self.assertEqual(cfg.transport_listen, "192.168.0.10")
        self.assertEqual(cfg.transport_port, 9876)

    def test_invalid_transport_port_rejected(self) -> None:
        with self.assertRaises(ConfigError):
            load_config(self._write("transport:\n  port: 70000\n"))

    def test_unknown_key_rejected(self) -> None:
        with self.assertRaises(ConfigError):
            load_config(self._write("collectors:\n  cpu:\n    enabled: false\n"))


if __name__ == "__main__":
    unittest.main()
