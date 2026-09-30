from pathlib import Path
import unittest


AGENT_ROOT = Path(__file__).resolve().parents[1]


class ServiceContractTests(unittest.TestCase):
    def test_systemd_execstart_uses_global_config_before_subcommand(self) -> None:
        unit = (AGENT_ROOT / "systemd" / "pulsedeck-agent.service").read_text(encoding="utf-8")
        self.assertIn(
            "ExecStart=/usr/bin/env pulsedeck-agent --config /etc/pulsedeck-agent/agent.yml run --state-dir /var/lib/pulsedeck-agent",
            unit,
        )
        self.assertNotIn("pulsedeck-agent run --config", unit)

    def test_service_uses_fixed_system_account(self) -> None:
        unit = (AGENT_ROOT / "systemd" / "pulsedeck-agent.service").read_text(encoding="utf-8")
        self.assertIn("User=pulsedeck-agent", unit)
        self.assertIn("Group=pulsedeck-agent", unit)
        self.assertNotIn("DynamicUser=yes", unit)
        self.assertIn("StateDirectoryMode=0755", unit)

    def test_sysusers_definition_exists(self) -> None:
        definition = (AGENT_ROOT / "systemd" / "pulsedeck-agent.sysusers").read_text(encoding="utf-8")
        self.assertIn('u pulsedeck-agent - "PulseDeck Agent service user"', definition)


if __name__ == "__main__":
    unittest.main()
