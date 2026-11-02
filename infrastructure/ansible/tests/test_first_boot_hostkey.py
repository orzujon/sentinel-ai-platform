"""Offline first-boot hostkey verifier contracts; no SSH and no VM connections."""
import base64
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_first_boot_hostkey import TrustBlocked, verify_identity, parse_public_key

def key(byte: int) -> str:
    wire = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + bytes([byte]) * 32
    return "ssh-ed25519 " + base64.b64encode(wire).decode("ascii")


class FirstBootHostkeyTests(unittest.TestCase):
    def test_valid_exact_match(self):
        for name, addr in [("sentinel-l1-cp01", "10.78.0.10"), ("sentinel-l1-w01", "10.78.0.11")]:
            result = verify_identity(name, addr, key(2), key(2))
            self.assertEqual(result["result"], "MATCH")
            self.assertFalse(result["knownHostsModified"])
            self.assertTrue(result["fingerprint"].startswith("SHA256:"))

    def test_different_keys_fail_closed(self):
        with self.assertRaisesRegex(TrustBlocked, "differs"):
            verify_identity("sentinel-l1-cp01", "10.78.0.10", key(1), key(2))

    def test_other_node_and_ip_fail(self):
        for name, addr in [("other-vm", "10.78.0.10"), ("sentinel-l1-cp01", "10.78.0.11"), ("sentinel-l1-w01", "10.78.0.10")]:
            with self.assertRaises(TrustBlocked):
                verify_identity(name, addr, key(1), key(1))

    def test_rejects_malformed_and_multi_line(self):
        for bad in ["", "ssh-rsa aGVsbG8=", key(1) + "\n" + key(2),
                    "ssh-ed25519 bm90LWEtcHVibGljLWtleQ==", "ssh-ed25519 !!!!"]:
            with self.assertRaises(TrustBlocked):
                parse_public_key(bad)


if __name__ == "__main__":
    unittest.main()
