from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from pulsedeck_agent.metadata import InstallInfo, load_install_info


class InstallInfoTests(unittest.TestCase):
    def test_reads_first_available_metadata_directory(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            second.mkdir()
            (second / "install-method").write_text("arch-package\n", encoding="utf-8")
            (second / "source-ref").write_text("dev\n", encoding="utf-8")
            (second / "source-revision").write_text("abc123\n", encoding="utf-8")

            info = load_install_info((first, second))

            self.assertEqual(info, InstallInfo("arch-package", "dev", "abc123"))

    def test_unmanaged_when_metadata_is_missing(self) -> None:
        with TemporaryDirectory() as tmp:
            info = load_install_info((Path(tmp) / "missing",))
            self.assertEqual(info, InstallInfo("unmanaged", "unknown", "unknown"))


if __name__ == "__main__":
    unittest.main()
