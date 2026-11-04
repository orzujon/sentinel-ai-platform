"""Offline-only provenance gate tests. No network, GPG, Hyper-V or WSL actions."""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "tools/verify_fresh_artifact_evidence.py"
spec = importlib.util.spec_from_file_location("fresh_artifact_evidence", SOURCE)
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class OfflineEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.good = json.loads(evidence.LOCK_PATH.read_text(encoding="utf-8"))

    def test_repository_stays_pending(self):
        self.assertEqual(self.good["review"]["status"], "pending-review")
        self.assertIsNone(self.good["review"]["approvedBy"])
        self.assertEqual(evidence.validate_lock(self.good), self.good)

    def test_exact_image_source_and_flannel_version(self):
        for key, value in (
            ("buildId", "20261017"),
            ("sha256", "latest"),
            ("imageRef", "ubuntu-24.04-20261016"),
            ("sourceUrl", "https://example.org/malicious-image.img"),
        ):
            bad = copy.deepcopy(self.good)
            bad["image"][key] = value
            with self.subTest(image=key), self.assertRaises(evidence.Blocked):
                evidence.validate_lock(bad)
        for key, value in (
            ("version", "v0.28.11"),
            ("sha256", "a" * 63),
            ("sourceUrl", "http://github.com/flannel-io/flannel/releases/foo"),
        ):
            bad = copy.deepcopy(self.good)
            bad["flannel"][key] = value
            with self.subTest(flannel=key), self.assertRaises(evidence.Blocked):
                evidence.validate_lock(bad)

    def test_unknown_profile_and_schema_fail_closed(self):
        for field, value in (("profile", "sentinel-l1-sandbox"),
                             ("schemaVersion", 2),
                             ("schemaVersion", True)):
            bad = copy.deepcopy(self.good)
            bad[field] = value
            with self.subTest(field=field), self.assertRaises(evidence.Blocked):
                evidence.validate_lock(bad)

    def test_signing_record_requires_unique_exact_filename(self):
        target = evidence.BUILD_FILE
        digest = "1" * 64
        self.assertEqual(evidence.signed_image_digest(
            f"{digest} *{target}\n".encode()), digest)
        for content in (b"not a sum", f"{digest} wrong-image.img\n".encode(),
                        (f"{digest}  {target}\n" * 2).encode()):
            with self.subTest(content=content), self.assertRaises(evidence.Blocked):
                evidence.signed_image_digest(content)

    def test_duplicate_json_keys_rejected(self):
        with self.assertRaises(evidence.Blocked):
            json.loads('{"profile":1,"profile":2}',
                       object_pairs_hook=evidence.unique_pairs)

    def test_source_only_reads_and_audits(self):
        source = SOURCE.read_text(encoding="utf-8")
        for required in (
            "KEY_FINGERPRINT",
            "gpgv",
            "SHA256SUMS.gpg",
            "signed_image_digest(sums)",
            "sha256_file(image)",
            "git_revision(",
            "publisherSignatureVerified\": False",
            "deploymentApproved\": False",
            "FRESH_ARTIFACT_PROVENANCE_PASS",
        ):
            self.assertIn(required, source)
        for prohibited in ("New-VM", "Remove-VM", "kubectl apply", "kubeadm init",
                           "FRESH_BOOTSTRAP", "Set-VMSwitch", "StrictHostKeyChecking=no"):
            if prohibited == "FRESH_BOOTSTRAP":
                # Only allowed as a blocking informational message.
                self.assertEqual(source.count(prohibited), 0)
            else:
                self.assertNotIn(prohibited, source)


if __name__ == "__main__":
    unittest.main()
