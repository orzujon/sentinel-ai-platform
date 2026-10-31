"""Offline desired-state and artifact integrity tests for unified Level 1 reconcile."""
from __future__ import annotations

import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import reconcile


class DesiredStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.config = Path(self.tmp.name) / "lab.yml"

    def write(self, digest: str, version="v0.28.10"):
        self.config.write_text(
            "schemaVersion: 1\nenvironment: lab\nkubernetes:\n"
            "  version: v1.37.2\n  podCIDR: 10.244.0.0/16\n"
            "  serviceCIDR: 10.96.0.0/12\n  flannel:\n"
            f"    version: {version}\n    manifestSHA256: {digest}\n"
        )

    def test_desired_state_is_locked(self):
        self.write("a" * 64)
        self.assertEqual(reconcile.load_desired(self.config, "lab")["version"], "v0.28.10")
        with self.assertRaises(reconcile.ReconcileError):
            reconcile.load_desired(self.config, "prod")
        self.write("a" * 64, version="latest")
        with self.assertRaises(reconcile.ReconcileError):
            reconcile.load_desired(self.config, "lab")

    def test_no_artifact_is_written_if_checksum_mismatches(self):
        payload = b"10.244.0.0/16\nghcr.io/flannel-io/flannel:v0.28.10\n" * 30
        target = Path(self.tmp.name) / "manifest.yml"
        with patch("reconcile.urllib.request.urlopen", return_value=io.BytesIO(payload)):
            with self.assertRaises(reconcile.ReconcileError):
                reconcile.retrieve_verified_release("v0.28.10", "0" * 64, target)
        self.assertFalse(target.exists())

    def test_exact_artifact_preserved(self):
        payload = b"10.244.0.0/16\nghcr.io/flannel-io/flannel:v0.28.10\n" * 30 + b"\n"
        target = Path(self.tmp.name) / "manifest.yml"
        with patch("reconcile.urllib.request.urlopen", return_value=io.BytesIO(payload)):
            reconcile.retrieve_verified_release("v0.28.10", hashlib.sha256(payload).hexdigest(), target)
        self.assertEqual(target.read_bytes(), payload)
        self.assertEqual(target.stat().st_mode & 0o077, 0)

    def test_apply_requires_approval_before_network_or_ansible(self):
        self.write("f" * 64)
        with patch("reconcile.retrieve_verified_release") as fetch:
            with self.assertRaises(reconcile.ReconcileError):
                reconcile.reconcile(inventory=Path("unused"), environment="lab",
                                    mode="apply", approval=False, state_root=Path(self.tmp.name),
                                    desired_file=self.config)
            fetch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
