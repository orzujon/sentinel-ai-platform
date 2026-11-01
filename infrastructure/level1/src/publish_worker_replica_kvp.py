#!/usr/bin/env python3
"""Sentinel Stage 5.3.3: publish the disposable guest's SSH PUBLIC host key via Hyper-V KVP.

Only the worker-shaped disposable VM may run this script. PLAN is read-only.
PUBLISH is a one-time, root-only, explicitly approved append to the daemon's
guest-to-host KVP pool 1; never copy or publish SSH private keys.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

VM_NAME = "sentinel-e2e-w02"
VM_IP = "10.78.0.12"
KVP_KEY = "Sentinel.SSHHostKey.Ed25519"
APPROVAL = "PUBLISH_DISPOSABLE_SENTINEL_W02_HOST_PUBLIC_KEY"
NONCE_FILE = Path("/var/lib/sentinel/provisioning-nonce")
HOST_PUBLIC_KEY_FILE = Path("/etc/ssh/ssh_host_ed25519_key.pub")
POOL_PATHS = (Path("/var/lib/hyperv/.kvp_pool_1"), Path("/var/opt/hyperv/.kvp_pool_1"))
KEY_SIZE = 512
VALUE_SIZE = 2048
RECORD_SIZE = KEY_SIZE + VALUE_SIZE
LIMIT_BYTES = 1024 * 1024
HOST_KEY_PATTERN = re.compile(r"^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})(?: [^\r\n]*)?$")
NONCE_PATTERN = re.compile(r"^[0-9a-f]{64}$")
KUBERNETES_MARKERS = (
    "/etc/kubernetes/admin.conf", "/etc/kubernetes/kubelet.conf",
    "/etc/kubernetes/bootstrap-kubelet.conf", "/var/lib/kubelet/config.yaml",
)


class Blocked(ValueError):
    pass


def public_key_bytes(text: str) -> bytes:
    if len(text) > 1024 or "\n" in text.strip() or "\r" in text.strip():
        raise Blocked("host public key is multiline or oversized")
    match = HOST_KEY_PATTERN.fullmatch(text.strip())
    if not match:
        raise Blocked("host public key is not a single ED25519 public key")
    try:
        wire = base64.b64decode(match.group(1), validate=True)
    except (ValueError, base64.binascii.Error) as exc:
        raise Blocked("invalid base64 host public key") from exc
    prefix = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    if len(wire) != 51 or not wire.startswith(prefix):
        raise Blocked("invalid SSH ED25519 wire format")
    if base64.b64encode(wire).decode("ascii").rstrip("=") != match.group(1).rstrip("="):
        raise Blocked("noncanonical SSH ED25519 encoding")
    return wire


def build_payload(nonce: str, public_key: str) -> str:
    if not NONCE_PATTERN.fullmatch(nonce):
        raise Blocked("invalid provisioner nonce")
    wire = public_key_bytes(public_key)
    canonical = "ssh-ed25519 " + base64.b64encode(wire).decode("ascii")
    digest = base64.b64encode(hashlib.sha256(wire).digest()).decode("ascii").rstrip("=")
    return json.dumps(
        {"schema": 1, "node": VM_NAME, "ip": VM_IP, "nonce": nonce,
         "publicKey": canonical, "fingerprint": "SHA256:" + digest},
        separators=(",", ":"), sort_keys=True,
    )


def encode_record(key: str, value: str) -> bytes:
    k = key.encode("ascii")
    v = value.encode("ascii")
    if not k or len(k) >= KEY_SIZE or not v or len(v) >= VALUE_SIZE:
        raise Blocked("KVP fixed-size record overflow")
    if b"\x00" in k or b"\x00" in v:
        raise Blocked("embedded NUL byte in KVP record")
    return k.ljust(KEY_SIZE, b"\x00") + v.ljust(VALUE_SIZE, b"\x00")


def decode_records(blob: bytes) -> list[tuple[str, str]]:
    if len(blob) % RECORD_SIZE:
        raise Blocked("corrupt or incomplete KVP pool record")
    records = []
    for offset in range(0, len(blob), RECORD_SIZE):
        piece = blob[offset:offset + RECORD_SIZE]
        key = piece[:KEY_SIZE].split(b"\x00", 1)[0]
        value = piece[KEY_SIZE:].split(b"\x00", 1)[0]
        try:
            records.append((key.decode("utf-8"), value.decode("utf-8")))
        except UnicodeDecodeError as exc:
            raise Blocked("invalid UTF-8 existing KVP pool record") from exc
    return records


def append_once(pool: Path, value: str, *, test_pool: bool = False) -> str:
    if os.name != "posix" or not sys.platform.startswith("linux"):
        raise Blocked("KVP pool writes require Linux")
    if not test_pool and pool not in POOL_PATHS:
        raise Blocked("unapproved KVP pool")
    import fcntl

    if pool.is_symlink() or not pool.is_file():
        raise Blocked("KVP pool is absent, symlinked, or not regular")
    fd = os.open(pool, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
    try:
        with os.fdopen(fd, "r+b", buffering=0) as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > LIMIT_BYTES:
                raise Blocked("KVP pool is invalid or oversized")
            if not test_pool and metadata.st_uid != 0:
                raise Blocked("KVP pool is not owned by root")
            fcntl.lockf(stream.fileno(), fcntl.LOCK_EX)
            try:
                blob = stream.read(LIMIT_BYTES + 1)
                if len(blob) > LIMIT_BYTES:
                    raise Blocked("KVP pool exceeded size limit")
                records = decode_records(blob)
                matching = [old for key, old in records if key == KVP_KEY]
                if len(matching) > 1:
                    raise Blocked("duplicate SSH identity records in KVP pool")
                if matching:
                    if matching[0] != value:
                        raise Blocked("SSH identity already published with different content")
                    return "UNCHANGED"
                record = encode_record(KVP_KEY, value)
                if len(blob) + RECORD_SIZE > LIMIT_BYTES:
                    raise Blocked("KVP pool has insufficient capacity")
                stream.seek(0, os.SEEK_END)
                if stream.write(record) != RECORD_SIZE:
                    raise Blocked("short KVP pool write")
                stream.flush()
                os.fsync(stream.fileno())
                return "CREATED"
            finally:
                fcntl.lockf(stream.fileno(), fcntl.LOCK_UN)
    except OSError as exc:
        raise Blocked("KVP pool read/write failed") from exc


def read_root_file(path: Path, *, limit: int = 1024) -> str:
    if path.is_symlink() or not path.is_file():
        raise Blocked("expected regular non-symlinked input")
    metadata = path.stat()
    if metadata.st_uid != 0 or metadata.st_size > limit:
        raise Blocked("unexpected file owner or size")
    return path.read_text(encoding="ascii").strip()


def preflight() -> tuple[Path, str]:
    if os.name != "posix" or not sys.platform.startswith("linux"):
        raise Blocked("guest must be Linux")
    if os.uname().nodename != VM_NAME:
        raise Blocked("wrong guest hostname")
    os_release = Path("/etc/os-release").read_text(encoding="utf-8")
    if not re.search(r'^ID=ubuntu$', os_release, re.MULTILINE) or not re.search(
        r'^VERSION_ID="?26\.04"?$', os_release, re.MULTILINE
    ):
        raise Blocked("expected Ubuntu 26.04")
    virt = subprocess.run(["systemd-detect-virt"], capture_output=True, text=True, check=False)
    if virt.returncode != 0 or virt.stdout.strip() != "microsoft":
        raise Blocked("guest is not running under Hyper-V")
    for marker in KUBERNETES_MARKERS:
        if Path(marker).exists():
            raise Blocked("Kubernetes installation marker present")
    daemon = subprocess.run(
        ["systemctl", "is-active", "--quiet", "hv-kvp-daemon.service"],
        capture_output=True, check=False,
    )
    if daemon.returncode != 0:
        raise Blocked("Hyper-V KVP daemon is not active")
    if not Path("/dev/vmbus/hv_kvp").is_char_device():
        raise Blocked("Hyper-V KVP VMBus character device missing")
    pools = [path for path in POOL_PATHS if path.is_file() and not path.is_symlink()]
    if len(pools) != 1:
        raise Blocked("expected exactly one daemon-created guest-to-host KVP pool")
    nonce = read_root_file(NONCE_FILE)
    public_key = read_root_file(HOST_PUBLIC_KEY_FILE)
    return pools[0], build_payload(nonce, public_key)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("plan", "publish"), required=True)
    parser.add_argument("--approval")
    args = parser.parse_args(argv)
    try:
        if args.mode == "publish" and args.approval != APPROVAL:
            raise Blocked("publication requires explicit disposable-only approval")
        # Every actual pool read/write requires sudo; no privilege escalation.
        if os.geteuid() != 0:
            raise Blocked("root privileges required to inspect private provisioning evidence")
        pool, payload = preflight()
        if args.mode == "plan":
            # Even PLAN validates existing pool record structure without writing.
            with pool.open("rb") as stream:
                records = decode_records(stream.read(LIMIT_BYTES + 1))
            matching = [v for k, v in records if k == KVP_KEY]
            if len(matching) > 1 or (matching and matching[0] != payload):
                raise Blocked("conflicting or duplicated guest identity record")
            print("KVP_PUBLICATION_PLAN_READY: exact disposable guest and host public key verified; no pool changes")
            return 0
        result = append_once(pool, payload)
        print("KVP_GUEST_PUBLICATION_" + result + ": host-side independent verification required")
        return 0
    except (Blocked, OSError, UnicodeError) as exc:
        print("BLOCKED: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
