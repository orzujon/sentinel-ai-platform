#!/usr/bin/env python3
"""Offline SSH identity comparison for a first-boot Sentinel guest.

The attested key MUST come from an independent trusted console or verified
provisioning record. A key fetched from the network alone cannot attest itself.
This helper never connects to a host, updates known_hosts or accepts trust.
"""
from __future__ import annotations
import argparse
import base64
import hashlib
from pathlib import Path
import re
import sys

ALLOWED = {"sentinel-l1-cp01", "sentinel-l1-w01"}
ADDRESS = {"sentinel-l1-cp01": "10.78.0.10", "sentinel-l1-w01": "10.78.0.11"}
PATTERN = re.compile(r"^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})(?: [^\r\n]*)?$")


class TrustBlocked(ValueError):
    pass


def parse_public_key(text: str) -> bytes:
    """Only accept one exact ed25519 host public-key line."""
    if not isinstance(text, str) or len(text) > 1024:
        raise TrustBlocked("Expected one bounded ed25519 host public-key record")
    line = text.strip()
    if "\n" in line or "\r" in line:
        raise TrustBlocked("Multiple lines or embedded control characters are prohibited")
    match = PATTERN.fullmatch(line)
    if match is None:
        raise TrustBlocked("Only single-line ssh-ed25519 public keys are supported")
    encoded = match.group(1)
    try:
        wire = base64.b64decode(encoded, validate=True)
    except (ValueError, base64.binascii.Error) as exc:
        raise TrustBlocked("Malformed host public-key encoding") from exc
    if base64.b64encode(wire).decode("ascii").rstrip("=") != encoded.rstrip("="):
        raise TrustBlocked("Noncanonical host public-key encoding")
    # SSH public-key wire format: length-prefixed algorithm and key bytes.
    algo = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    if len(wire) != len(algo) + 32 or not wire.startswith(algo):
        raise TrustBlocked("Invalid ed25519 host public-key wire format")
    return wire


def fingerprint(key: bytes) -> str:
    return "SHA256:" + base64.b64encode(hashlib.sha256(key).digest()).decode("ascii").rstrip("=")


def verify_identity(node: str, address: str, attested: str, observed: str) -> dict:
    if node not in ALLOWED or address != ADDRESS.get(node):
        raise TrustBlocked("Node name / IP must match the pinned isolated sandbox")
    trusted_key = parse_public_key(attested)
    candidate_key = parse_public_key(observed)
    if trusted_key != candidate_key:
        raise TrustBlocked("Observed SSH host identity differs from the independently attested key")
    return {"result": "MATCH", "node": node, "address": address,
            "fingerprint": fingerprint(trusted_key), "knownHostsModified": False}


def read_private_file(path: Path) -> str:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024:
        raise TrustBlocked("Expected a small regular, non-symlink host key input file")
    return path.read_text(encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Offline first-boot SSH key attestation comparison")
    parser.add_argument("--node", required=True, choices=sorted(ALLOWED))
    parser.add_argument("--address", required=True)
    parser.add_argument("--attested-file", type=Path, required=True,
                        help="Public host key obtained through an independent trusted console")
    parser.add_argument("--observed-file", type=Path, required=True,
                        help="Untrusted candidate host key retrieved over the network")
    args = parser.parse_args(argv)
    try:
        result = verify_identity(args.node, args.address,
                                 read_private_file(args.attested_file),
                                 read_private_file(args.observed_file))
    except (OSError, UnicodeError, TrustBlocked) as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2
    print(f"HOST_IDENTITY_MATCH: {result['node']} {result['fingerprint']}")
    print("VERIFICATION_ONLY: no keys trusted, installed, or modified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
