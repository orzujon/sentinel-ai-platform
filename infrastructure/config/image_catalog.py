"""Offline, read-only Sentinel image catalog inspection.

A matching catalog record is NOT proof that publisher signatures were verified.
Catalog integrity is pinned separately from the environment Git revision.
This module never downloads images, fetches credentials or changes infrastructure.
"""
from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from urllib.parse import urlparse

SCHEMA = "sentinel.image-catalog/v1"
HEX = re.compile(r"^[a-fA-F0-9]{64}$")
REF = re.compile(r"^[a-z][a-z0-9.-]{1,79}$")


class CatalogError(ValueError):
    pass


def _pairs_unique(pairs):
    result = {}
    for k, v in pairs:
        if k in result:
            raise CatalogError("Duplicate catalog JSON key")
        result[k] = v
    return result


def _utc_timestamp(value):
    if not isinstance(value, str):
        raise CatalogError("Catalog approval timestamp is invalid")
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise CatalogError("Catalog approval timestamp is invalid") from exc
    if stamp.tzinfo is None:
        raise CatalogError("Catalog approval timestamp must include UTC offset")
    if stamp.astimezone(timezone.utc).year < 2020:
        raise CatalogError("Catalog approval timestamp is outside policy")
    return stamp


def resolve_catalog(raw: bytes, pinned_catalog_sha256: str, image: dict):
    """Return offline metadata match; NEVER authorise execution from this result."""
    if not isinstance(pinned_catalog_sha256, str) or not HEX.fullmatch(pinned_catalog_sha256):
        raise CatalogError("Expected approved catalog SHA256 digest (64 hex)")
    if len(raw) > 256_000:
        raise CatalogError("Catalog exceeds maximum size")
    digest = hashlib.sha256(raw).hexdigest()
    if digest != pinned_catalog_sha256.lower():
        raise CatalogError("Catalog file digest differs from independent operator pin")
    try:
        catalog = json.loads(raw, object_pairs_hook=_pairs_unique)
    except (ValueError, UnicodeDecodeError) as exc:
        raise CatalogError("Invalid catalog JSON") from exc
    if (not isinstance(catalog, dict) or set(catalog) != {"schemaVersion", "images"}
            or catalog["schemaVersion"] != SCHEMA):
        raise CatalogError("Unsupported catalog schema")
    entries = catalog["images"]
    if not isinstance(entries, list) or len(entries) > 500:
        raise CatalogError("Invalid catalog image list")
    ids = set()
    matching = None
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "id", "sourceUrl", "buildId", "sha256", "state", "approvedBy", "approvedAt",
        }:
            raise CatalogError("Unexpected catalog image fields")
        ref = entry["id"]
        if not isinstance(ref, str) or not REF.fullmatch(ref) or ref in ids:
            raise CatalogError("Invalid or duplicated catalog image ID")
        ids.add(ref)
        if entry["state"] not in ("candidate", "approved", "deprecated", "revoked"):
            raise CatalogError("Invalid catalog image state")
        if entry["state"] == "approved":
            if not isinstance(entry["sha256"], str) or not HEX.fullmatch(entry["sha256"]):
                raise CatalogError("Approved catalog image missing SHA256")
            if not isinstance(entry["approvedBy"], str) or not re.fullmatch(
                r"[a-zA-Z0-9._@-]{3,80}", entry["approvedBy"]
            ):
                raise CatalogError("Approved image missing reviewer identity")
            _utc_timestamp(entry["approvedAt"])
        else:
            if entry["sha256"] is not None and (
                not isinstance(entry["sha256"], str) or not HEX.fullmatch(entry["sha256"])
            ):
                raise CatalogError("Malformed candidate image digest")
        if (not isinstance(entry["sourceUrl"], str) or
                not isinstance(entry["buildId"], str)):
            raise CatalogError("Malformed catalog identity")
        src = urlparse(entry["sourceUrl"])
        if src.scheme != "https" or src.hostname != "cloud-images.ubuntu.com":
            raise CatalogError("Catalog source is not allowlisted Canonical HTTPS")
        if entry["id"] == image.get("imageRef"):
            matching = entry
    if not image.get("imageRef") or not isinstance(image["imageRef"], str):
        raise CatalogError("Environment imageRef is required for catalog lookup")
    if matching is None:
        raise CatalogError("Image reference missing from trusted catalog")
    if matching["state"] != "approved":
        raise CatalogError("Image reference is not approved (candidate/deprecated/revoked)")
    if (matching["sourceUrl"] != image["sourceUrl"] or
            matching["buildId"] != image["buildId"]):
        raise CatalogError("Image identity differs between environment and catalog")
    if image["expectedSha256"] is not None and (
        image["expectedSha256"].lower() != matching["sha256"].lower()
    ):
        raise CatalogError("Environment expected SHA256 disagrees with approved catalog")
    # Approval metadata has not been independently signed/verified by this
    # tool. A pinned catalog merely detects changes relative to an operator pin.
    return {
        "status": "PINNED_CATALOG_METADATA_MATCH",
        "imageRef": matching["id"],
        "imageSha256": matching["sha256"].lower(),
        "catalogSha256": digest,
        "artifactSignatureVerified": False,
        "deploymentPermitted": False,
    }
