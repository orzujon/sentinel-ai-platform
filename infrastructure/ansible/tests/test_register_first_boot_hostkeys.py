"""No network, no Hyper-V: first-boot trust store registration regression tests."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from register_first_boot_hostkeys import APPROVAL, NODES, register
from verify_first_boot_hostkey import TrustBlocked
from test_first_boot_hostkey import key


class RegisterFirstBootTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "private"
        self.root.mkdir(mode=0o700)
        self.a = {}
        self.o = {}
        for i, node in enumerate(NODES, 1):
            a = self.root / (node + ".console.pub")
            o = self.root / (node + ".network.pub")
            a.write_text(key(i), encoding="ascii")
            o.write_text(key(i), encoding="ascii")
            self.a[node] = a
            self.o[node] = o

    def apply(self, **overrides):
        args = {"attested": self.a, "observed": self.o,
                "private_root": self.root, "approval": APPROVAL,
                "attestation_reviewed": True}
        args.update(overrides)
        return register(**args)

    def test_exact_two_distinct_nodes_are_registered_privately(self):
        result = self.apply()
        self.assertEqual(result["status"], "REGISTERED")
        output = self.root / "firstboot-known_hosts"
        lines = output.read_text().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].startswith("10.78.0.10 ssh-ed25519 "))
        self.assertTrue(lines[1].startswith("10.78.0.11 ssh-ed25519 "))
        if os.name != "nt":
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(TrustBlocked):
            self.apply()
        self.assertEqual(output.read_text().splitlines(), lines)

    def test_approval_is_required(self):
        with self.assertRaisesRegex(TrustBlocked, "approval"):
            self.apply(approval=None)
        with self.assertRaisesRegex(TrustBlocked, "attestation"):
            self.apply(attestation_reviewed=False)
        self.assertFalse((self.root / "firstboot-known_hosts").exists())

    def test_mismatch_refuses_all_writes(self):
        self.o[NODES[1]].write_text(key(8))
        with self.assertRaisesRegex(TrustBlocked, "differs"):
            self.apply()
        self.assertFalse((self.root / "firstboot-known_hosts").exists())

    def test_duplicate_vm_host_identity_blocked(self):
        self.a[NODES[1]].write_text(key(1))
        self.o[NODES[1]].write_text(key(1))
        with self.assertRaisesRegex(TrustBlocked, "identical"):
            self.apply()
        self.assertFalse((self.root / "firstboot-known_hosts").exists())

    def test_same_source_file_is_not_independent_evidence(self):
        self.o[NODES[0]] = self.a[NODES[0]]
        with self.assertRaisesRegex(TrustBlocked, "same file"):
            self.apply()

    def test_unapproved_inventory_fails(self):
        with self.assertRaisesRegex(TrustBlocked, "exact identities"):
            self.apply(attested={NODES[0]: self.a[NODES[0]]})

    def test_symlink_destination_rejected(self):
        destination = self.root / "firstboot-known_hosts"
        destination.symlink_to(self.root / (NODES[0] + ".console.pub"))
        with self.assertRaises(TrustBlocked):
            self.apply()

    def test_wrong_destination_directory_permissions_rejected(self):
        if os.name == "nt":
            return
        self.root.chmod(0o755)
        with self.assertRaisesRegex(TrustBlocked, "readable"):
            self.apply()


if __name__ == "__main__":
    unittest.main()
