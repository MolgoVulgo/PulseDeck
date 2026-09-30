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
        self.assertIn('makepkg -Cs --noconfirm', script)
        self.assertNotIn('cd "$SCRIPT_DIR"', script)


    def test_arch_installer_uses_single_noninteractive_sudo_session(self) -> None:
        script = (AGENT_ROOT / "packaging" / "arch" / "install.sh").read_text(encoding="utf-8")
        self.assertIn("sudo -v", script)
        self.assertIn("sudo -n true", script)
        self.assertIn('sudo -n "$@"', script)
        self.assertIn("pacman -U --noconfirm", script)
        self.assertIn('PACMAN="$PACMAN_WRAPPER"', script)
        self.assertIn('exec sudo -n "$PACMAN_BIN" "\\$@"', script)
        self.assertNotIn("makepkg -Csi", script)
        self.assertNotIn("makepkg -Csi --noconfirm", script)

    def test_arch_installer_filters_only_known_benign_fakeroot_line_on_success(self) -> None:
        script = (AGENT_ROOT / "packaging" / "arch" / "install.sh").read_text(encoding="utf-8")
        self.assertIn("libfakeroot internal error: payload not recognized!", script)
        self.assertIn('if [[ $MAKEPKG_RC -ne 0 ]]', script)
        self.assertIn('cat "$MAKEPKG_STDERR" >&2', script)

    def test_arch_pkgbuild_can_pin_exact_source_commit(self) -> None:
        pkgbuild = (AGENT_ROOT / "packaging" / "arch" / "PKGBUILD").read_text(encoding="utf-8")
        self.assertIn('_pulsedeck_commit="${PULSEDECK_COMMIT:-}"', pkgbuild)
        self.assertIn('#commit=${_pulsedeck_commit}', pkgbuild)
        self.assertIn('#branch=${_pulsedeck_ref}', pkgbuild)

    def test_agent_packaging_keeps_transport_module_with_runtime(self) -> None:
        pkgbuild = (AGENT_ROOT / "packaging" / "arch" / "PKGBUILD").read_text(encoding="utf-8")
        pyproject = (AGENT_ROOT / "pyproject.toml").read_text(encoding="utf-8")
        standalone = (AGENT_ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
        self.assertTrue((AGENT_ROOT / "src" / "pulsedeck_agent" / "http_server.py").is_file())
        self.assertIn("cp -a agent/src/pulsedeck_agent", pkgbuild)
        self.assertIn('where = ["src"]', pyproject)
        self.assertIn('pip install --disable-pip-version-check --upgrade --force-reinstall "$SOURCE/agent"', standalone)

    def test_arch_update_reuses_clean_installer(self) -> None:
        script = (AGENT_ROOT / "scripts" / "update.sh").read_text(encoding="utf-8")
        self.assertIn('helper="/usr/share/pulsedeck-agent/arch/install.sh"', script)
        self.assertIn('exec "$helper" "$REF"', script)
        self.assertNotIn('makepkg -Csi', script)


if __name__ == "__main__":
    unittest.main()
