"""Catalog tests use only synthetic metadata; no real image is approved."""
import hashlib
import importlib.util
import json
import pathlib
import sys
import unittest

BASE = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE))
spec = importlib.util.spec_from_file_location("sentinel_planner_for_catalog", BASE / "plan.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)

IMAGE = {
    "imageRef": "ubuntu-26.04-20261016",
    "sourceUrl": "https://cloud-images.ubuntu.com/releases/26.04/release-20261016/ubuntu-26.04-server-cloudimg-amd64.img",
    "buildId": "20261016",
    "expectedSha256": None,
}
FAKE_DIGEST = "a" * 64
FAKE_RECORD = {
    "id": IMAGE["imageRef"],
    "sourceUrl": IMAGE["sourceUrl"],
    "buildId": IMAGE["buildId"],
    "sha256": FAKE_DIGEST,
    "state": "approved",
    "approvedBy": "fixture-reviewer",
    "approvedAt": "2026-10-01T12:00:00Z",
}


def encoded(doc):
    raw = json.dumps(doc, sort_keys=True).encode("utf-8")
    return raw, hashlib.sha256(raw).hexdigest()


class TestImageCatalog(unittest.TestCase):
    def setUp(self):
        self.catalog = {"schemaVersion": "sentinel.image-catalog/v1",
                        "images": [dict(FAKE_RECORD)]}
        self.image = dict(IMAGE)

    def assert_blocked(self):
        raw, pin = encoded(self.catalog)
        with self.assertRaises(planner.ConfigError):
            planner.build_plan(self.load_config(), "a" * 40, "lab",
                               catalog_data=raw, catalog_sha256=pin)

    def load_config(self):
        text = (BASE / "fixtures" / "lab.example.yaml").read_text(encoding="utf-8")
        data = planner.parse_yaml(text)
        data["spec"]["image"] = dict(self.image, distribution="Ubuntu", architecture="amd64")
        return data

    def test_approved_metadata_only_never_permits_deployment(self):
        raw, pin = encoded(self.catalog)
        result = planner.build_plan(self.load_config(), "a" * 40, "lab",
                                    catalog_data=raw, catalog_sha256=pin)
        self.assertEqual(result["imageCatalog"]["status"], "PINNED_CATALOG_METADATA_MATCH")
        self.assertFalse(result["imageCatalog"]["artifactSignatureVerified"])
        self.assertFalse(result["imageCatalog"]["deploymentPermitted"])
        self.assertFalse(result["deploymentPermitted"])
        self.assertEqual(result["imageCatalog"]["imageSha256"], FAKE_DIGEST)

    def test_reject_tampered_catalog(self):
        raw, pin = encoded(self.catalog)
        with self.assertRaises(planner.ConfigError):
            planner.build_plan(self.load_config(), "a" * 40, "lab",
                               catalog_data=raw + b" ", catalog_sha256=pin)

    def test_reject_revoked(self):
        self.catalog["images"][0]["state"] = "revoked"
        self.assert_blocked()

    def test_reject_candidate(self):
        self.catalog["images"][0]["state"] = "candidate"
        self.assert_blocked()

    def test_reject_unlisted_ref(self):
        self.catalog["images"][0]["id"] = "another-image"
        self.assert_blocked()

    def test_reject_wrong_upstream_url(self):
        self.catalog["images"][0]["sourceUrl"] = "https://example.org/bad.img"
        self.assert_blocked()

    def test_reject_wrong_digest(self):
        self.image["expectedSha256"] = "b" * 64
        self.assert_blocked()

    def test_reject_duplicate_json_keys(self):
        raw = b'{"schemaVersion":"sentinel.image-catalog/v1","schemaVersion":"sentinel.image-catalog/v1","images":[]}'
        with self.assertRaises(planner.ConfigError):
            planner.build_plan(self.load_config(), "a" * 40, "lab",
                               catalog_data=raw, catalog_sha256=hashlib.sha256(raw).hexdigest())

    def test_reject_unapproved_catalog_hash(self):
        raw, pin = encoded(self.catalog)
        with self.assertRaises(planner.ConfigError):
            planner.build_plan(self.load_config(), "a" * 40, "lab",
                               catalog_data=raw, catalog_sha256="b" * 64)

    def test_reject_missing_approval_reviewer(self):
        self.catalog["images"][0]["approvedBy"] = ""
        self.assert_blocked()

    def test_reject_missing_image_ref(self):
        self.image.pop("imageRef")
        self.assert_blocked()


if __name__ == "__main__":
    unittest.main()
