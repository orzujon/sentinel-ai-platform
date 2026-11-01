"""Stage 5.4 offline guest KVP publisher tests; no live Hyper-V or SSH."""
import base64
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SRC = Path(__file__).resolve().parents[1] / "src" / "publish_firstboot_kvp.py"
spec = importlib.util.spec_from_file_location("stage54_publisher", SRC)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def good_key(seed=42):
    wire = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + bytes([seed])*32
    return "ssh-ed25519 " + base64.b64encode(wire).decode("ascii")


def config(slot=20, nonce="a"*64):
    return {"schema": 2, "node": f"sentinel-e2e-auto{slot}", "ip": f"10.78.0.{slot}", "nonce": nonce}


class FirstBootKvpTests(unittest.TestCase):
    def test_disposable_parameterised_slot_and_schema(self):
        for slot in range(20, 30):
            record = json.loads(mod.build_value(config(slot), good_key()))
            self.assertEqual(record["node"], f"sentinel-e2e-auto{slot}")
            self.assertEqual(record["ip"], f"10.78.0.{slot}")
            self.assertEqual(record["nonce"], "a"*64)
            self.assertEqual(record["schema"], 1)
            self.assertEqual(record["publicKey"], good_key())
            self.assertRegex(record["fingerprint"], r"^SHA256:[A-Za-z0-9+/]+$")

    def test_rejects_live_node_or_wrong_slot(self):
        for invalid in [
            config(10), config(12), config(19), config(30), config(100),
            dict(config(), node="sentinel-l1-w01"),
            dict(config(), ip="10.78.0.11"),
            dict(config(), nonce="NOT-NONCE"),
            dict(config(), schema=1),
            dict(config(), unexpected="injection"),
        ]:
            with self.subTest(invalid=invalid):
                with self.assertRaises(mod.Blocked):
                    mod.build_value(invalid, good_key())

    def test_fixed_size_daemon_binary_record(self):
        value = mod.build_value(config(), good_key())
        row = mod.encode_record(mod.KVP_KEY, value)
        self.assertEqual(len(row), 2560)
        self.assertEqual(mod.decode_records(row), [(mod.KVP_KEY,value)])

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux pool test")
    def test_append_once_preserves_other_daemon_records_and_refuses_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            pool = Path(directory)/".kvp_pool_1"
            initial = mod.encode_record("Other.Key", "preserve")
            pool.write_bytes(initial)
            value = mod.build_value(config(), good_key())
            self.assertEqual(mod.publish(pool, value, fixture=True), "CREATED")
            captured = pool.read_bytes()
            self.assertEqual(mod.publish(pool, value, fixture=True), "UNCHANGED")
            self.assertEqual(captured, pool.read_bytes())
            self.assertEqual(mod.decode_records(captured)[0], ("Other.Key","preserve"))
            with self.assertRaisesRegex(mod.Blocked, "collision"):
                mod.publish(pool, mod.build_value(config(), good_key(43)), fixture=True)
            self.assertEqual(captured, pool.read_bytes())

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux pool test")
    def test_corrupt_file_duplicate_symlink_never_written(self):
        with tempfile.TemporaryDirectory() as directory:
            pool = Path(directory)/".kvp_pool_1"
            pool.write_bytes(b"bad-record")
            with self.assertRaisesRegex(mod.Blocked,"incomplete"):
                mod.publish(pool,"{}",fixture=True)
            self.assertEqual(pool.read_bytes(),b"bad-record")
            val = mod.build_value(config(),good_key())
            pool.write_bytes(mod.encode_record(mod.KVP_KEY,val)*2)
            with self.assertRaisesRegex(mod.Blocked,"duplicate"):
                mod.publish(pool,val,fixture=True)
            real = Path(directory)/"real"
            real.write_bytes(b"")
            pool.unlink()
            pool.symlink_to(real)
            with self.assertRaises(mod.Blocked):
                mod.publish(pool,val,fixture=True)
            self.assertEqual(real.read_bytes(),b"")

    def test_firstboot_candidate_check_avoids_early_exit_pipefail(self):
        sh = SRC.with_name("firstboot-kvp-setup.sh").read_text("utf-8")
        self.assertIn('policy="$(apt-cache policy "$package")"', sh)
        self.assertIn('FIRSTBOOT_KVP_CANDIDATE:', sh)
        self.assertNotIn("awk '/Candidate:/ {print $2; exit}'", sh)
        self.assertIn("apt-get install -y", sh)

    def test_regression_previous_live_kvp_recovery_requires_targeted_udev_activation(self):
        sh = SRC.with_name("firstboot-kvp-setup.sh").read_text("utf-8")
        self.assertIn("linux-cloud-tools-${kernel}", sh)
        self.assertIn("udevadm control --reload", sh)
        self.assertIn('udevadm trigger --action=add "$device"', sh)
        self.assertIn("udevadm settle --timeout=20", sh)
        self.assertIn("unit='sys-devices-virtual-misc-vmbus\\x21hv_kvp.device'", sh)
        self.assertNotIn("unit='sys-devices-virtual-misc-vmbus\\\\x21hv_kvp.device'", sh)
        self.assertIn("systemctl is-active --quiet hv-kvp-daemon.service", sh)
        self.assertIn("--no-remove", sh)
        self.assertNotIn("udevadm trigger --action=add --subsystem-match", sh)

    def test_invalid_host_key_encoding_never_embedded(self):
        for pub in ("ssh-rsa AAAA","ssh-ed25519 !!!","not-a-key",good_key()+"\n"+good_key()):
            with self.subTest(pub=pub[:20]):
                with self.assertRaises(mod.Blocked):
                    mod.build_value(config(),pub)

    def test_config_and_package_shell_require_fail_closed_before_ssh(self):
        source = SRC.read_text("utf-8")
        sh = SRC.with_name("firstboot-kvp-setup.sh").read_text("utf-8")
        for required in (
            "sentinel-e2e-auto", "os.O_NOFOLLOW", "fcntl.lockf",
            "PUBLISH_FIRSTBOOT_SENTINEL_KVP_PUBLIC_HOST_KEY",
            "/var/lib/hyperv/.kvp_pool_1", "/etc/ssh/ssh_host_ed25519_key.pub",
            "/etc/kubernetes/admin.conf", "systemd-detect-virt",
        ):
            self.assertIn(required,source)
        for required in (
            "set -euo pipefail", "apt-get update", "linux-cloud-tools-common",
            "linux-cloud-tools-", "hv-kvp-daemon.service",
            "PUBLISH_FIRSTBOOT_SENTINEL_KVP_PUBLIC_HOST_KEY",
            "FIRSTBOOT_KVP_GUEST_READY",
        ):
            self.assertIn(required,sh)
        self.assertNotIn("ssh-keyscan",sh)
        self.assertNotIn("accept-new",sh)


if __name__ == "__main__":
    unittest.main()
