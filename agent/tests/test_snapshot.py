import unittest

from pulsedeck_agent.collectors.metric import failed_reading, ok_reading
from pulsedeck_agent.models.snapshot import AgentIdentity, build_snapshot


class SnapshotTests(unittest.TestCase):
    def test_optional_invalid_metric_is_not_zero(self) -> None:
        valid_pct = ok_reading(value=12.5, source="test", unit="percent")
        invalid = failed_reading(source="test", unit="watt", error="missing")
        snapshot = build_snapshot(
            identity=AgentIdentity("mini-server", "Mini Server"),
            cpu={"pct": valid_pct, "temp_c": invalid, "power_w": invalid},
            memory={
                "used_b": ok_reading(value=1, source="test", unit="bytes"),
                "total_b": ok_reading(value=2, source="test", unit="bytes"),
                "pct": valid_pct,
            },
            network={
                "interface": "eth0",
                "rx_bps": invalid,
                "tx_bps": invalid,
                "rx_bytes": ok_reading(value=3, source="test", unit="bytes"),
                "tx_bytes": ok_reading(value=4, source="test", unit="bytes"),
            },
            gpu=None,
        )
        self.assertIsNone(snapshot["cpu"]["power_w"]["value_raw"])
        self.assertFalse(snapshot["cpu"]["power_w"]["valid"])
        self.assertTrue(snapshot["state"]["ok"])


if __name__ == "__main__":
    unittest.main()
