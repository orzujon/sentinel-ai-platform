"""Stage 5.3 Linux KVP publisher synthetic-pool safety tests (never touch VMs)."""
import base64
import json
import sys
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from publish_guest_kvp_hostkey import (
    build_value, decode_records, encode_record, publish, KVP_KEY, RECORD_SIZE,
)
from verify_first_boot_hostkey import TrustBlocked


def fake_key(byte):
    wire = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + bytes([byte]) * 32
    return "ssh-ed25519 " + base64.b64encode(wire).decode("ascii")


class PublishGuestKvpTests(unittest.TestCase):
    def test_serialization_uses_binary_fixed_size_record(self):
        payload = build_value("sentinel-l1-cp01", "10.78.0.10", "a" * 64, fake_key(1))
        row = encode_record(KVP_KEY, payload)
        self.assertEqual(len(row), RECORD_SIZE)
        self.assertEqual(decode_records(row), [(KVP_KEY, payload)])
        record = json.loads(payload)
        self.assertEqual(record["schema"], 1)
        self.assertEqual(record["nonce"], "a" * 64)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'KVP file locking requires Linux')
    def test_publish_to_disposable_pool_only_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            pool = Path(tmp) / ".kvp_pool_1"
            pool.write_bytes(encode_record("Other.Key", "other data"))
            value = build_value("sentinel-l1-w01", "10.78.0.11", "b" * 64, fake_key(2))
            publish(pool, value, allowed_path=False)
            saved = pool.read_bytes()
            self.assertEqual(len(saved), 2 * RECORD_SIZE)
            self.assertEqual(decode_records(saved)[-1], (KVP_KEY, value))
            with self.assertRaisesRegex(TrustBlocked, "already published"):
                publish(pool, value, allowed_path=False)
            self.assertEqual(saved, pool.read_bytes())

    @unittest.skipUnless(sys.platform.startswith('linux'), 'KVP file locking requires Linux')
    def test_bad_pool_cannot_be_modified(self):
        with tempfile.TemporaryDirectory() as tmp:
            pool = Path(tmp) / "pool"
            pool.write_bytes(b"partial record")
            before = pool.read_bytes()
            with self.assertRaisesRegex(TrustBlocked, "incomplete"):
                publish(pool, "data", allowed_path=False)
            self.assertEqual(pool.read_bytes(), before)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'KVP file locking requires Linux')
    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = Path(tmp) / "pool"
            link = Path(tmp) / "link"
            real.touch()
            link.symlink_to(real)
            with self.assertRaises(TrustBlocked):
                publish(link, "data", allowed_path=False)

    @unittest.skipIf(sys.platform.startswith('linux'), 'Windows-specific failure gate')
    def test_non_linux_publication_is_blocked(self):
        with tempfile.TemporaryDirectory() as tmp:
            pool = Path(tmp) / 'pool'
            pool.touch()
            with self.assertRaisesRegex(TrustBlocked, 'only inside a Linux guest'):
                publish(pool, 'ignored', allowed_path=False)

    def test_wrong_host_or_nonce_rejected(self):
        with self.assertRaises(TrustBlocked):
            build_value("sentinel-l1-cp01", "10.78.0.11", "a" * 64, fake_key(1))
        with self.assertRaises(TrustBlocked):
            build_value("sentinel-l1-cp01", "10.78.0.10", "not-a-nonce", fake_key(1))


if __name__ == "__main__":
    unittest.main()
