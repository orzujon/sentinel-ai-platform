#!/usr/bin/env python3
"""Read-only Sentinel fresh-cluster artifact provenance verifier.

Runs in Ubuntu WSL with access to the Windows Stage2 cache. Downloads only
publisher verification metadata, a public signing key and the pinned Flannel
manifest. Never writes to or mutates VM, Kubernetes, trust or image-cache state.
A PASS is evidence for human approval, NOT a deployment approval.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request
from urllib.parse import urlparse

KEY_FINGERPRINT = "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81"
KEY_URL = "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x" + KEY_FINGERPRINT
PROFILE = "sentinel-fresh-cluster-v1"
BUILD_FILE = "ubuntu-26.04-server-cloudimg-amd64.img"
LOCK_PATH = Path(__file__).resolve().parents[1] / "config/fresh-artifacts.lock.json"
CACHE_ROOT = Path("/mnt/c/Sentinel/ImageCache")
IMAGE_PATTERN = re.compile(r"^([a-fA-F0-9]{64})[ \t]+\*?" + re.escape(BUILD_FILE) + r"\r?$", re.MULTILINE)
SHA256 = re.compile(r"^[a-f0-9]{64}$")


class Blocked(ValueError):
    pass


def unique_pairs(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise Blocked("Duplicate JSON key: " + key)
        obj[key] = value
    return obj


def read_json(path: Path, limit: int) -> tuple[dict, bytes]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > limit:
        raise Blocked("Missing, linked or oversized required metadata: " + path.name)
    content = path.read_bytes()
    try:
        data = json.loads(content, object_pairs_hook=unique_pairs)
    except (ValueError, UnicodeError) as exc:
        raise Blocked("Invalid metadata JSON: " + path.name) from exc
    if not isinstance(data, dict):
        raise Blocked("JSON root is not an object")
    return data, content


def validate_lock(data: dict) -> dict:
    if (set(data) != {"schemaVersion", "profile", "review", "image", "flannel"}
            or type(data["schemaVersion"]) is not int or data["schemaVersion"] != 1
            or data["profile"] != PROFILE):
        raise Blocked("Unsupported artifact profile")
    image, flannel, review = data["image"], data["flannel"], data["review"]
    if (not all(isinstance(x, dict) for x in (image, flannel, review))
            or set(image) != {"imageRef", "buildId", "sourceUrl", "sha256"}
            or set(flannel) != {"version", "sourceUrl", "sha256"}
            or set(review) != {"status", "approvedBy", "approvedAtUtc", "approvalReference"}):
        raise Blocked("Unexpected profile fields")
    build = image["buildId"]
    if (not isinstance(build, str) or not re.fullmatch(r"20[0-9]{6}", build)
            or image["imageRef"] != "ubuntu-26.04-" + build
            or not isinstance(image["sha256"], str) or not SHA256.fullmatch(image["sha256"])
            or image["sourceUrl"] != (
                "https://cloud-images.ubuntu.com/releases/26.04/release-"
                + build + "/" + BUILD_FILE)):
        raise Blocked("Unapproved or malformed Canonical image specification")
    if (flannel["version"] != "v0.28.10"
            or not isinstance(flannel["sha256"], str)
            or not SHA256.fullmatch(flannel["sha256"])
            or flannel["sourceUrl"] != (
                "https://github.com/flannel-io/flannel/releases/download/"
                + flannel["version"] + "/kube-flannel.yml")):
        raise Blocked("Unapproved or malformed Flannel specification")
    if review["status"] not in ("pending-review", "approved"):
        raise Blocked("Unknown review state")
    # Verification never makes or relies on a self-reported approval decision.
    return data


def signed_image_digest(sums: bytes) -> str:
    if len(sums) > 250_000:
        raise Blocked("Canonical SHA256SUMS file too large")
    try:
        text = sums.decode("ascii")
    except UnicodeDecodeError as exc:
        raise Blocked("Canonical checksum list must be ASCII") from exc
    matches = IMAGE_PATTERN.findall(text)
    if len(matches) != 1:
        raise Blocked("Signed checksum list has no unique pinned image entry")
    return matches[0].lower()


def ensure_unlinked(path: Path) -> None:
    for part in (path, *path.parents):
        if part.is_symlink():
            raise Blocked("Linked artifact/cache path is forbidden")
    if not path.is_file():
        raise Blocked("Expected pinned artifact is missing")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            chunk = source.read(4 * 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def check_local_image(lock: dict) -> tuple[Path, int]:
    image_spec = lock["image"]
    folder = CACHE_ROOT / "ubuntu" / "26.04" / image_spec["buildId"]
    image = folder / (image_spec["sha256"] + ".img")
    metadata_path = folder / (image_spec["sha256"] + ".json")
    ensure_unlinked(image)
    ensure_unlinked(metadata_path)
    metadata, _ = read_json(metadata_path, 8192)
    if (metadata.get("sourceUrl") != image_spec["sourceUrl"]
            or metadata.get("buildId") != image_spec["buildId"]
            or metadata.get("sha256") != image_spec["sha256"]
            or type(metadata.get("sizeBytes")) is not int
            or metadata["sizeBytes"] != image.stat().st_size):
        raise Blocked("Stage2 image sidecar does not match locked build, source and size")
    if sha256_file(image) != image_spec["sha256"]:
        raise Blocked("Stage2 cached image digest mismatch")
    return image, image.stat().st_size


def download(url: str, allowed_hosts: set[str], limit: int) -> bytes:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in allowed_hosts:
        raise Blocked("Verification download uses an unapproved endpoint")
    request = urllib.request.Request(url, headers={"User-Agent": "Sentinel-Artifact-Attestation/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=35) as response:
            final = urlparse(response.geturl())
            if final.scheme != "https" or final.hostname not in allowed_hosts:
                raise Blocked("Verification download redirected outside HTTPS allowlist")
            payload = response.read(limit + 1)
    except (OSError, TimeoutError) as exc:
        raise Blocked("Verification source unavailable: " + str(type(exc).__name__)) from exc
    if not 0 < len(payload) <= limit:
        raise Blocked("Verification payload empty or oversized")
    return payload


def verify_canonical_signature(key: bytes, sums: bytes, signature: bytes, temp: Path) -> None:
    home = temp / "gnupg"
    home.mkdir(mode=0o700)
    for name, contents in (("key.asc", key), ("SHA256SUMS", sums), ("SHA256SUMS.gpg", signature)):
        (temp / name).write_bytes(contents)
    imported = subprocess.run(
        ["gpg", "--batch", "--no-tty", "--homedir", str(home), "--import", str(temp / "key.asc")],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=30)
    if imported.returncode:
        raise Blocked("Cannot import Ubuntu publisher public key")
    listed = subprocess.run(
        ["gpg", "--batch", "--no-tty", "--homedir", str(home), "--with-colons",
         "--fingerprint", "--list-keys"], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False, timeout=15)
    if listed.returncode:
        raise Blocked("Cannot inspect signing-key fingerprint")
    # Only one primary public key may be imported; its first fingerprint is pinned
    # to Canonical's independently documented Ubuntu cloud-image signing key.
    lines = listed.stdout.splitlines()
    fingerprints = [l.split(":")[9].upper() for l in lines if l.startswith("fpr:")]
    primary_keys = sum(l.startswith("pub:") for l in lines)
    if primary_keys != 1 or not fingerprints or fingerprints[0] != KEY_FINGERPRINT:
        raise Blocked("Ubuntu signing key fingerprint does not match Canonical pin")
    keyring = temp / "ubuntu-image-signing-key.gpg"
    with keyring.open("wb") as output:
        exported = subprocess.run(
            ["gpg", "--batch", "--no-tty", "--homedir", str(home), "--export", KEY_FINGERPRINT],
            stdout=output, stderr=subprocess.PIPE, check=False, timeout=15)
    if exported.returncode or keyring.stat().st_size < 100:
        raise Blocked("Cannot export pinned verifier key")
    verified = subprocess.run(
        ["gpgv", "--keyring", str(keyring), str(temp / "SHA256SUMS.gpg"),
         str(temp / "SHA256SUMS")], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        check=False, timeout=30)
    if verified.returncode:
        raise Blocked("Canonical SHA256SUMS publisher signature failed verification")


def git_revision(root: Path) -> str:
    def git(*args):
        run = subprocess.run(["git", "-C", str(root), *args], text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             check=False, timeout=15)
        if run.returncode:
            raise Blocked("Cannot verify clean Git checkout")
        return run.stdout.strip()
    revision = git("rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", revision) or git("status", "--porcelain"):
        raise Blocked("Evidence requires a clean, immutable Git working-tree revision")
    return revision


def attest() -> Path:
    if os.name != "posix" or not str(Path.home()).startswith("/home/"):
        raise Blocked("Run using the Ubuntu WSL controller, not elevated Windows")
    lock, raw = read_json(LOCK_PATH, 8192)
    validate_lock(lock)
    revision = git_revision(LOCK_PATH.parents[3])
    image, size = check_local_image(lock)
    build = lock["image"]["buildId"]
    base = "https://cloud-images.ubuntu.com/releases/26.04/release-" + build + "/"
    sums = download(base + "SHA256SUMS", {"cloud-images.ubuntu.com"}, 250_000)
    signature = download(base + "SHA256SUMS.gpg", {"cloud-images.ubuntu.com"}, 64_000)
    key = download(KEY_URL, {"keyserver.ubuntu.com"}, 64_000)
    with tempfile.TemporaryDirectory(prefix="sentinel-artifact-proof-") as d:
        verify_canonical_signature(key, sums, signature, Path(d))
    if signed_image_digest(sums) != lock["image"]["sha256"]:
        raise Blocked("Publisher-signed checksum disagrees with locked/cached image SHA256")
    # Flannel has a reviewed exact release SHA256, not a Canonical-style
    # publisher signature. Integrity verified; publisher authenticity unproven.
    flannel = download(lock["flannel"]["sourceUrl"],
                       {"github.com", "objects.githubusercontent.com",
                        "release-assets.githubusercontent.com"}, 250_000)
    if hashlib.sha256(flannel).hexdigest() != lock["flannel"]["sha256"]:
        raise Blocked("Flannel release download does not match reviewed SHA256 pin")
    state = Path.home() / ".local/state/sentinel-fresh/attestations"
    for p in (state, *state.parents):
        if p.is_symlink():
            raise Blocked("Linked private attestation-state path")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    if state.stat().st_mode & 0o077:
        raise Blocked("Private attestation directory has overly broad permissions")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    evidence = {
        "schemaVersion": "sentinel.fresh-artifact-provenance/v1",
        "createdAtUtc": datetime.now(timezone.utc).isoformat(),
        "status": "verified-evidence-not-deployment-approval",
        "gitCommit": revision,
        "profile": PROFILE,
        "profileLockSHA256": hashlib.sha256(raw).hexdigest(),
        "reviewStatus": lock["review"]["status"],
        "ubuntu": {"imageRef": lock["image"]["imageRef"],
                   "sourceUrl": lock["image"]["sourceUrl"],
                   "cachedPath": str(image),
                   "sizeBytes": size,
                   "imageSHA256": lock["image"]["sha256"],
                   "signedChecksumManifestSHA256": hashlib.sha256(sums).hexdigest(),
                   "signatureFileSHA256": hashlib.sha256(signature).hexdigest(),
                   "signerFingerprint": KEY_FINGERPRINT,
                   "signatureValidatedWith": "gpgv",
                   "signedImageChecksumMatched": True,
                   "cachedImageChecksumMatched": True},
        "flannel": {"version": lock["flannel"]["version"],
                    "sourceUrl": lock["flannel"]["sourceUrl"],
                    "upstreamSHA256": lock["flannel"]["sha256"],
                    "checksumMatched": True,
                    "publisherSignatureVerified": False},
        "deploymentApproved": False
    }
    fd, path = tempfile.mkstemp(prefix=stamp + "-", suffix=".json", dir=state)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as target:
            json.dump(evidence, target, indent=2)
            target.write("\n")
        os.chmod(path, 0o600)
    except BaseException:
        Path(path).unlink(missing_ok=True)
        raise
    return Path(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    try:
        result = attest()
    except (Blocked, OSError, subprocess.TimeoutExpired) as exc:
        print("BLOCKED: " + str(exc), file=sys.stderr)
        return 1
    print("FRESH_ARTIFACT_PROVENANCE_PASS: Canonical signature, signed image SHA256,"
          " local image and upstream Flannel SHA256 verified")
    print("FRESH_ARTIFACT_PROVENANCE_AUDIT: " + str(result))
    print("FRESH_ARTIFACT_APPROVAL: PENDING human review; this does not authorize BOOTSTRAP")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
