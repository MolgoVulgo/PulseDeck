from pulsedeck_hub.collectors.mini_server import MiniServerCollector
from pulsedeck_hub.config import MiniServerConfig


def test_mini_server_scaffold_is_explicitly_transport_pending() -> None:
    collector = MiniServerCollector(MiniServerConfig(enabled=True, host="192.168.0.1"))

    collector.start()
    status = collector.status()

    assert collector.running is True
    assert collector.transport_ready is False
    assert status == {
        "enabled": True,
        "host": "192.168.0.1",
        "profile": "mini-server",
        "transport": "unresolved",
        "collecting": False,
    }

    collector.stop()
    assert collector.running is False
