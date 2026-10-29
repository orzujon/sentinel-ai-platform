"""Stage 4.1 trust bootstrap tests with fake keys and fictional inventory."""
import importlib.util
from pathlib import Path
import os
import stat
import tempfile
import unittest
from unittest import mock
import subprocess

MODULE = Path(__file__).resolve().parents[1] / "run_readiness.py"
spec = importlib.util.spec_from_file_location("stage4_runner", MODULE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

SAMPLE_KEY = "192.0.2.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKey=="
OTHER_KEY = "192.0.2.11 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIWorkerKey=="


class TestTrustedControllerBootstrap(unittest.TestCase):
    def test_keys_copied_from_previously_trusted_store_only(self):
        with tempfile.TemporaryDirectory() as d:
            dest = Path(d) / "pinned-known-hosts"
            (Path(d) / "windows").touch()
            def fake_ssh(cmd, **_):
                self.assertEqual(cmd[0:2], ["ssh-keygen", "-F"])
                record = SAMPLE_KEY if cmd[2] == "192.0.2.10" else OTHER_KEY
                return subprocess.CompletedProcess(cmd, 0, stdout="# Host found\n" + record + "\n", stderr="")
            with mock.patch.object(runner.subprocess, "run", side_effect=fake_ssh):
                runner.prepare_host_trust(
                    ["192.0.2.10", "192.0.2.11"], Path(d)/"windows", dest
                )
            self.assertEqual(dest.read_text(), SAMPLE_KEY + "\n" + OTHER_KEY + "\n")
            if os.name != "nt":
                self.assertEqual(stat.S_IMODE(dest.stat().st_mode), 0o600)

    def test_missing_trusted_host_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            known = Path(d) / "windows"
            known.touch()
            with mock.patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 1, stdout="", stderr=""
            )):
                with self.assertRaises(runner.Stage4Blocked):
                    runner.trusted_entries(known, "192.0.2.10")

    def test_changed_pinned_trust_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            dest = Path(d) / "pinned"
            runner.persist_immutable(dest, SAMPLE_KEY + "\n")
            with self.assertRaises(runner.Stage4Blocked):
                runner.persist_immutable(dest, OTHER_KEY + "\n")
            self.assertEqual(dest.read_text(), SAMPLE_KEY + "\n")

    def test_duplicate_target_rejected(self):
        with self.assertRaises(runner.Stage4Blocked):
            runner.prepare_host_trust(
                ["192.0.2.10", "192.0.2.10"], Path("/nonexistent"), Path("/tmp/unwritten")
            )

    @unittest.skipIf(os.name == "nt", "POSIX symlink behaviour")
    def test_symlink_not_followed(self):
        with tempfile.TemporaryDirectory() as d:
            protected = Path(d) / "protected"
            protected.write_text("preserve")
            symlink = Path(d) / "pinned"
            symlink.symlink_to(protected)
            with self.assertRaises(runner.Stage4Blocked):
                runner.persist_immutable(symlink, SAMPLE_KEY + "\n")
            self.assertEqual(protected.read_text(), "preserve")


if __name__ == "__main__":
    unittest.main()
