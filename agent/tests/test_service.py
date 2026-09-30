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

    def test_arch_installer_builds_from_clean_remote_checkout(self) -> None:
        script = (AGENT_ROOT / "packaging" / "arch" / "install.sh").read_text(encoding="utf-8")
        self.assertIn('git clone --quiet --depth 1 --branch "$REF"', script)
        self.assertIn('TMP="$(mktemp -d)"', script)
        self.assertIn('PULSEDECK_COMMIT="$REVISION" makepkg -Csi --noconfirm', script)
        self.assertNotIn('cd "$SCRIPT_DIR"', script)

    def test_arch_pkgbuild_can_pin_exact_source_commit(self) -> None:
        pkgbuild = (AGENT_ROOT / "packaging" / "arch" / "PKGBUILD").read_text(encoding="utf-8")
        self.assertIn('_pulsedeck_commit="${PULSEDECK_COMMIT:-}"', pkgbuild)
        self.assertIn('#commit=${_pulsedeck_commit}', pkgbuild)
        self.assertIn('#branch=${_pulsedeck_ref}', pkgbuild)

    def test_arch_update_reuses_clean_installer(self) -> None:
        script = (AGENT_ROOT / "scripts" / "update.sh").read_text(encoding="utf-8")
        self.assertIn('helper="/usr/share/pulsedeck-agent/arch/install.sh"', script)
        self.assertIn('exec "$helper" "$REF"', script)
        self.assertNotIn('makepkg -Csi', script)


if __name__ == "__main__":
    unittest.main()
