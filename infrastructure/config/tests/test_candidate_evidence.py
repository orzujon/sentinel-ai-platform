"""Public candidate evidence is explicitly non-authorising and safe to share."""
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CANDIDATE = ROOT / "image-catalog" / "candidates" / "ubuntu-26.04-20261016.json"


class TestCandidateEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.evidence = json.loads(CANDIDATE.read_text(encoding="utf-8"))

    def test_observed_image_identity(self):
        record = self.evidence
        self.assertEqual(record["imageRef"], "ubuntu-26.04-20261016")
        self.assertEqual(record["buildId"], "20261016")
        self.assertTrue(re.fullmatch(r"[a-f0-9]{64}", record["sha256"]))
        self.assertEqual(record["sourceUrl"],
                         "https://cloud-images.ubuntu.com/releases/26.04/release-20261016/ubuntu-26.04-server-cloudimg-amd64.img")

    def test_candidate_cannot_be_treated_as_authorised(self):
        record = self.evidence
        self.assertEqual(record["state"], "candidate")
        self.assertEqual(record["trust"], "operator-reported")
        self.assertIs(record["deploymentPermitted"], False)
        self.assertNotIn("approvedBy", record)
        self.assertNotIn("approvedAt", record)

    def test_signing_key_recorded_but_not_attested(self):
        record = self.evidence
        self.assertEqual(record["observations"]["signerFingerprint"],
                         "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81")
        self.assertIn("Machine-generated reproducible verification attestation",
                      record["notYetEstablished"][0])

    def test_no_private_paths_or_keys(self):
        raw = CANDIDATE.read_text(encoding="utf-8").lower()
        for forbidden in ("c:\\users", "c:\\sentinel", "private_key", "password",
                          "access_token", "secret_value"):
            self.assertNotIn(forbidden, raw)


if __name__ == "__main__":
    unittest.main()
