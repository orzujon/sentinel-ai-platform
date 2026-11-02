#!/usr/bin/env python3
"""Stage 5.3: guarded Ubuntu -> Hyper-V KVP guest identity publisher.

Microsoft documents pool 1 as guest-to-host and fixed-sized binary records:
512 bytes key + 2048 bytes value. This script operates ONLY on an existing
daemon-created pool, under a POSIX advisory file lock; never on live Kubernetes
guests. No private host keys are read. Caller-supplied provisioning nonce
must originate from the trusted Hyper-V/cloud-init provisioning manifest.

It does NOT prove SSH identity by itself. The controller must check host-side
VM ID, one-time nonce, KVP key and network-observed host key before trust.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import stat
import sys

from verify_first_boot_hostkey import parse_public_key, fingerprint, TrustBlocked

KEY_SIZE = 512
VALUE_SIZE = 2048
RECORD_SIZE = KEY_SIZE + VALUE_SIZE
KVP_KEY = "Sentinel.SSHHostKey.Ed25519"
APPROVAL = "PUBLISH_FRESH_SENTINEL_KVP_HOSTKEY"
EXPECTED = {
    "sentinel-l1-cp01": "10.78.0.10",
    "sentinel-l1-w01": "10.78.0.11",
}
POOL_PATHS = (
    Path("/var/lib/hyperv/.kvp_pool_1"),
    Path("/var/opt/hyperv/.kvp_pool_1"),
)
NONCE_RE = re.compile(r"^[a-f0-9]{64}$")


def encode_record(key: str, value: str) -> bytes:
    name = key.encode("ascii")
    data = value.encode("ascii")
    if not name or len(name) >= KEY_SIZE or len(data) >= VALUE_SIZE:
        raise TrustBlocked("KVP record exceeds fixed-size limits")
    if b"\x00" in name or b"\x00" in data:
        raise TrustBlocked("NUL in KVP record")
    return name.ljust(KEY_SIZE, b"\x00") + data.ljust(VALUE_SIZE, b"\x00")


def decode_records(blob: bytes) -> list[tuple[str, str]]:
    if len(blob) % RECORD_SIZE:
        raise TrustBlocked("KVP pool contains incomplete or corrupt records")
    output = []
    for i in range(0, len(blob), RECORD_SIZE):
        record = blob[i:i + RECORD_SIZE]
        try:
            name = record[:KEY_SIZE].split(b"\x00", 1)[0].decode("utf-8")
            value = record[KEY_SIZE:].split(b"\x00", 1)[0].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise TrustBlocked("Malformed KVP record encoding") from exc
        output.append((name, value))
    return output


def build_value(node: str, ip: str, nonce: str, host_public_key: str) -> str:
    if node not in EXPECTED or ip != EXPECTED[node]:
        raise TrustBlocked("Non-Sentinel guest or IP identity")
    if not NONCE_RE.fullmatch(nonce):
        raise TrustBlocked("Provisioning nonce must be a 32-byte hex random value")
    wire = parse_public_key(host_public_key)
    payload = {"schema": 1, "node": node, "ip": ip, "nonce": nonce,
               "publicKey": "ssh-ed25519 " + base64.b64encode(wire).decode("ascii"),
               "fingerprint": fingerprint(wire)}
    return json.dumps(payload, separators=(",", ":"), sort_keys=True)


def publish(pool: Path, record_value: str, *, allowed_path: bool = True) -> None:
    if os.name != 'posix' or not sys.platform.startswith('linux'):
        raise TrustBlocked('KVP pool publication is supported only inside a Linux guest')
    import fcntl  # Linux-only; Windows can import and test validation functions.
    if allowed_path and pool not in POOL_PATHS:
        raise TrustBlocked("Only the supported Hyper-V guest KVP pool is permitted")
    if pool.is_symlink() or not pool.is_file():
        raise TrustBlocked("KVP pool absent, not regular or symlinked")
    flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(pool, flags)
    try:
        with os.fdopen(fd, "r+b", buffering=0) as stream:
            initial = os.fstat(stream.fileno())
            if not stat.S_ISREG(initial.st_mode) or initial.st_size > 1024 * 1024:
                raise TrustBlocked("KVP pool type or size is unsafe")
            fcntl.lockf(stream.fileno(), fcntl.LOCK_EX)
            try:
                existing = stream.read()
                entries = decode_records(existing)
                if any(k == KVP_KEY for k, _ in entries):
                    raise TrustBlocked("Host identity already published; no update or replacement")
                # Guest KVP pool is daemon-owned. Append a complete, fixed-size
                # record under the same POSIX lock used by the Linux daemon.
                stream.seek(0, os.SEEK_END)
                blob = encode_record(KVP_KEY, record_value)
                wrote = stream.write(blob)
                if wrote != len(blob):
                    raise OSError("Incomplete KVP append")
                stream.flush()
                os.fsync(stream.fileno())
            finally:
                fcntl.lockf(stream.fileno(), fcntl.LOCK_UN)
    except OSError as exc:
        raise TrustBlocked("KVP pool read/write failed") from exc


def main(argv=None):
    parser = argparse.ArgumentParser(description="Fresh-only Ubuntu guest KVP identity publisher")
    parser.add_argument("--node", choices=sorted(EXPECTED), required=True)
    parser.add_argument("--ip", required=True)
    parser.add_argument("--nonce-file", type=Path, required=True,
                        help="Fresh, private provisioning nonce from trusted cloud-init seed")
    parser.add_argument("--host-key-file", type=Path, default=Path("/etc/ssh/ssh_host_ed25519_key.pub"))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--approval")
    args = parser.parse_args(argv)
    try:
        if args.host_key_file != Path("/etc/ssh/ssh_host_ed25519_key.pub"):
            raise TrustBlocked("Only the system-generated host public key may be published")
        nonce = args.nonce_file.read_text(encoding="ascii").strip()
        public = args.host_key_file.read_text(encoding="ascii")
        value = build_value(args.node, args.ip, nonce, public)
        # All checks before accessing the real binary KVP store.
        if not args.apply:
            print("PLAN_ONLY: valid host key and provisioning nonce; no pool touched")
            return 0
        if args.approval != APPROVAL or not hasattr(os, 'geteuid') or os.geteuid() != 0:
            raise TrustBlocked("Explicit fresh-VM approval and root privileges required")
        if any(Path(path).exists() for path in (
            "/etc/kubernetes/admin.conf", "/etc/kubernetes/kubelet.conf",
            "/var/lib/kubelet/config.yaml", "/etc/kubernetes/bootstrap-kubelet.conf"
        )):
            raise TrustBlocked("Existing Kubernetes state; refusing KVP publisher")
        pools = [p for p in POOL_PATHS if p.is_file() and not p.is_symlink()]
        if len(pools) != 1:
            raise TrustBlocked("Exactly one daemon-created KVP guest pool must exist")
        publish(pools[0], value)
        print("PUBLISHED: guest key evidence only; controller verification still required")
        return 0
    except (TrustBlocked, OSError, UnicodeError) as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
