#!/usr/bin/env python3
"""Stage 5.3 trusted first-boot SSH registration (offline, fresh lab only).

Only creates a NEW, private, dedicated known_hosts file after independently
attested and network-observed ed25519 keys match for BOTH approved nodes.
Never reads network, edits an existing known_hosts, or replaces an existing file.
The operator must review the independent console evidence before approval.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from verify_first_boot_hostkey import (
    ADDRESS, TrustBlocked, parse_public_key, read_private_file, verify_identity,
)

APPROVAL = "REGISTER_NEW_SENTINEL_HOST_IDENTITIES"
NODES = ("sentinel-l1-cp01", "sentinel-l1-w01")


def validate_destination(destination: Path, private_root: Path) -> None:
    if private_root.is_symlink() or not private_root.is_dir():
        raise TrustBlocked("Private state directory must exist and not be a symlink")
    if os.name != "nt" and private_root.stat().st_mode & 0o077:
        raise TrustBlocked("Private state directory must not be readable by group/others")
    if destination.parent != private_root:
        raise TrustBlocked("Trusted-host file must be a direct child of private state directory")
    if destination.name != "firstboot-known_hosts":
        raise TrustBlocked("Refusing to write existing SSH known_hosts or arbitrary filenames")
    if destination.is_symlink() or destination.exists():
        raise TrustBlocked("Trusted-host file already exists; no adoption or replacement allowed")


def build_known_hosts(attested: dict, observed: dict) -> tuple[str, list[dict]]:
    if set(attested) != set(NODES) or set(observed) != set(NODES):
        raise TrustBlocked("Require exact identities for both approved sandbox VMs")
    rows = []
    matches = []
    for name in NODES:
        # Inputs are independent in provenance, not just different filenames.
        attested_path = Path(attested[name])
        observed_path = Path(observed[name])
        if attested_path.resolve() == observed_path.resolve():
            raise TrustBlocked("Attested and observed SSH key inputs cannot be the same file")
        independently_attested = read_private_file(attested_path)
        network_observed = read_private_file(observed_path)
        match = verify_identity(name, ADDRESS[name], independently_attested, network_observed)
        wire = parse_public_key(independently_attested)
        import base64
        encoded = base64.b64encode(wire).decode("ascii")
        rows.append(f"{ADDRESS[name]} ssh-ed25519 {encoded}")
        matches.append(match)
    if rows[0].split(" ", 1)[1] == rows[1].split(" ", 1)[1]:
        raise TrustBlocked("Two fresh VMs have identical SSH host identities; refuse clone reuse")
    return "\n".join(rows) + "\n", matches


def register(*, attested: dict, observed: dict, private_root: Path,
             approval: str | None, attestation_reviewed: bool) -> dict:
    if approval != APPROVAL or not attestation_reviewed:
        raise TrustBlocked("Separate explicit approval and independently reviewed console attestation required")
    destination = private_root / "firstboot-known_hosts"
    validate_destination(destination, private_root)
    body, matches = build_known_hosts(attested, observed)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(destination, flags, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="ascii", newline="\n") as output:
            output.write(body)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        # Never silently remove or overwrite a partially created trust record.
        raise
    return {"status": "REGISTERED", "knownHosts": str(destination),
            "hosts": [{"node": m["node"], "fingerprint": m["fingerprint"]} for m in matches]}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Register independently verified fresh VM SSH host identities")
    parser.add_argument("--cp-attested", type=Path, required=True)
    parser.add_argument("--cp-observed", type=Path, required=True)
    parser.add_argument("--worker-attested", type=Path, required=True)
    parser.add_argument("--worker-observed", type=Path, required=True)
    parser.add_argument("--private-root", type=Path, required=True)
    parser.add_argument("--approval", required=True)
    parser.add_argument("--attestation-reviewed", action="store_true",
                        help="Explicit operator confirmation of independent, trusted console evidence")
    args = parser.parse_args(argv)
    try:
        result = register(
            attested={NODES[0]: args.cp_attested, NODES[1]: args.worker_attested},
            observed={NODES[0]: args.cp_observed, NODES[1]: args.worker_observed},
            private_root=args.private_root, approval=args.approval,
            attestation_reviewed=args.attestation_reviewed,
        )
    except (OSError, UnicodeError, TrustBlocked) as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    print("WARNING: no network connection or SSH authenticity probe was performed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
