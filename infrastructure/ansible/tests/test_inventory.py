"""Stage 4 inventory contract tests, using invented hosts/TEST-NET addresses."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

FILE = Path(__file__).resolve().parents[1] / "render_inventory.py"
spec = importlib.util.spec_from_file_location("stage4_inventory", FILE)
inventory_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory_module)


class TestInventory(unittest.TestCase):
    def setUp(self):
        self.validated = {
            "identity": {"username": "fictional-operator"},
            "vms": [
                {"name": "example-control", "role": "control-plane", "staticIP": "192.0.2.10"},
                {"name": "example-worker", "role": "worker", "staticIP": "192.0.2.11"},
            ],
        }

    def test_inventory_group_membership(self):
        data = inventory_module.build_inventory(self.validated)
        self.assertEqual(data["sentinel_control_plane"]["hosts"], ["example-control"])
        self.assertEqual(data["sentinel_workers"]["hosts"], ["example-worker"])
        self.assertEqual(set(data["_meta"]["hostvars"]), {"example-control", "example-worker"})
        self.assertEqual(data["sentinel_sandbox"]["children"],
                         ["sentinel_control_plane", "sentinel_workers"])

    def test_inventory_has_private_ssh_safeguards_not_keys(self):
        data = inventory_module.build_inventory(self.validated)
        serialized = json.dumps(data)
        self.assertIn("StrictHostKeyChecking=yes", serialized)
        self.assertIn("PasswordAuthentication=no", serialized)
        self.assertNotIn("private_key", serialized.lower())
        self.assertNotIn("ansible_ssh_private_key_file", serialized.lower())

    def test_inventory_uses_only_supplied_validated_values(self):
        data = inventory_module.build_inventory(self.validated)
        h = data["_meta"]["hostvars"]["example-control"]
        self.assertEqual(h["ansible_host"], "192.0.2.10")
        self.assertEqual(h["ansible_user"], "fictional-operator")
        self.assertEqual(h["sentinel_expected_hostname"], "example-control")

    @unittest.skipIf(os.name == "nt", "POSIX permission test")
    def test_inventory_saved_privately_without_overwrite(self):
        data = inventory_module.build_inventory(self.validated)
        with tempfile.TemporaryDirectory() as d:
            with mock.patch.object(Path, "home", return_value=Path(d)):
                output = inventory_module.save_private_inventory(data, "a" * 40, "example")
                self.assertTrue(output.exists())
                self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(output.parent.stat().st_mode), 0o700)
                with self.assertRaises(FileExistsError):
                    inventory_module.save_private_inventory(data, "a" * 40, "example")


if __name__ == "__main__":
    unittest.main()
