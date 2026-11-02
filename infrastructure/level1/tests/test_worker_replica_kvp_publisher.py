"""Stage 5.3.3 offline tests: only public SSH host identity into Hyper-V KVP pool 1."""
import base64
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

PUBLISHER = Path(__file__).resolve().parents[1] / "src" / "publish_worker_replica_kvp.py"
SPEC = importlib.util.spec_from_file_location("worker_replica_publisher", PUBLISHER)
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


def key(seed=7):
    wire = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + bytes([seed]) * 32
    return "ssh-ed25519 " + base64.b64encode(wire).decode("ascii")


def value(seed=7, nonce="a" * 64):
    return mod.build_payload(nonce, key(seed))


class DisposableKvpPublisherTests(unittest.TestCase):
    def test_exact_pinned_disposable_identity_and_fingerprint(self):
        doc = json.loads(value())
        self.assertEqual(doc["node"], "sentinel-e2e-w02")
        self.assertEqual(doc["ip"], "10.78.0.12")
        self.assertEqual(doc["schema"], 1)
        self.assertEqual(doc["nonce"], "a" * 64)
        self.assertEqual(doc["publicKey"], key())
        self.assertRegex(doc["fingerprint"], r"^SHA256:[A-Za-z0-9+/]+$")

    def test_fixed_size_record_and_decoding(self):
        record = mod.encode_record(mod.KVP_KEY, value())
        self.assertEqual(len(record), 512 + 2048)
        self.assertEqual(mod.decode_records(record), [(mod.KVP_KEY, value())])

    def test_duplicate_publication_is_idempotent_and_no_replacement(self):
        if not sys.platform.startswith("linux"):
            self.skipTest("fcntl requires Linux")
        with tempfile.TemporaryDirectory() as directory:
            pool = Path(directory) / ".kvp_pool_1"
            initial = mod.encode_record("Other.Key", "preserve")
            pool.write_bytes(initial)
            self.assertEqual(mod.append_once(pool, value(), test_pool=True), "CREATED")
            written = pool.read_bytes()
            self.assertTrue(written.startswith(initial))
            self.assertEqual(len(written), 2 * mod.RECORD_SIZE)
            self.assertEqual(mod.append_once(pool, value(), test_pool=True), "UNCHANGED")
            self.assertEqual(written, pool.read_bytes())
            with self.assertRaisesRegex(mod.Blocked, "different content"):
                mod.append_once(pool, value(seed=8), test_pool=True)
            self.assertEqual(written, pool.read_bytes())

    def test_corrupt_pool_is_untouched(self):
        if not sys.platform.startswith("linux"):
            self.skipTest("fcntl requires Linux")
        with tempfile.TemporaryDirectory() as directory:
            pool = Path(directory) / ".kvp_pool_1"
            pool.write_bytes(b"incomplete")
            with self.assertRaisesRegex(mod.Blocked, "incomplete"):
                mod.append_once(pool, value(), test_pool=True)
            self.assertEqual(pool.read_bytes(), b"incomplete")

    def test_symlink_pool_rejected(self):
        if not sys.platform.startswith("linux"):
            self.skipTest("fcntl requires Linux")
        with tempfile.TemporaryDirectory() as directory:
            real = Path(directory) / "real"
            real.write_bytes(b"")
            link = Path(directory) / ".kvp_pool_1"
            link.symlink_to(real)
            with self.assertRaises(mod.Blocked):
                mod.append_once(link, value(), test_pool=True)
            self.assertEqual(real.read_bytes(), b"")

    def test_duplicate_preexisting_identity_rejected(self):
        if not sys.platform.startswith("linux"):
            self.skipTest("fcntl requires Linux")
        with tempfile.TemporaryDirectory() as directory:
            pool = Path(directory) / ".kvp_pool_1"
            pool.write_bytes(
                mod.encode_record(mod.KVP_KEY, value()) +
                mod.encode_record(mod.KVP_KEY, value())
            )
            with self.assertRaisesRegex(mod.Blocked, "duplicate"):
                mod.append_once(pool, value(), test_pool=True)

    def test_invalid_nonce_and_non_ed25519_rejected(self):
        for bad_nonce in ("not-a-nonce", "A" * 64, "a" * 65):
            with self.subTest(nonce=bad_nonce):
                with self.assertRaises(mod.Blocked):
                    mod.build_payload(bad_nonce, key())
        for bad_key in ("ssh-rsa AAA=", "ssh-ed25519 @@@", key() + "\n" + key()):
            with self.subTest(key=bad_key[:30]):
                with self.assertRaises(mod.Blocked):
                    mod.build_payload("a" * 64, bad_key)

    def test_oversized_or_incomplete_pool_records_rejected(self):
        with self.assertRaises(mod.Blocked):
            mod.encode_record("k" * 512, "v")
        with self.assertRaises(mod.Blocked):
            mod.encode_record("k", "v" * 2048)
        with self.assertRaises(mod.Blocked):
            mod.decode_records(b"a" * 100)

    def test_kernel_vm_and_kubernetes_protection_contracts_present(self):
        source = PUBLISHER.read_text(encoding="utf-8")
        for expected in (
            "sentinel-e2e-w02", "10.78.0.12", "systemd-detect-virt",
            "PUBLISH_DISPOSABLE_SENTINEL_W02_HOST_PUBLIC_KEY",
            "/var/lib/sentinel/provisioning-nonce",
            "/etc/ssh/ssh_host_ed25519_key.pub",
            "/etc/kubernetes/admin.conf",
            "hv-kvp-daemon.service",
            "fcntl.lockf",
            "os.O_NOFOLLOW",
            "os.fsync",
            "KVP_PUBLICATION_PLAN_READY",
        ):
            self.assertIn(expected, source)
        self.assertNotIn("ssh_host_ed25519_key\"", source)
        self.assertNotIn("ssh_host_ed25519_key'", source)


if __name__ == "__main__":
    unittest.main()
