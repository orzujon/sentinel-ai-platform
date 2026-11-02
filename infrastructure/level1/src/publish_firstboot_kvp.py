#!/usr/bin/env python3
"""Sentinel Stage 5.4: publish a fresh VM's *public* SSH host key without SSH.

Designed to ship INSIDE cloud-init's seed ISO before first boot. The VM's
root-owned config and host's independent provisioning manifest carry the same
per-VM nonce. The Hyper-V host later binds this evidence to its actual VM UUID.
No private key is read, copied, or used here.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

KVP_KEY = "Sentinel.SSHHostKey.Ed25519"
APPROVAL = "PUBLISH_FIRSTBOOT_SENTINEL_KVP_PUBLIC_HOST_KEY"
CONFIG = Path("/etc/sentinel/bootstrap.json")
PUBKEY = Path("/etc/ssh/ssh_host_ed25519_key.pub")
POOLS = (Path("/var/lib/hyperv/.kvp_pool_1"), Path("/var/opt/hyperv/.kvp_pool_1"))
RECORD = 512 + 2048
POOL_MAX = 1024 * 1024
NAME_RE = re.compile(r"^sentinel-e2e-auto(2[0-9])$")
NONCE_RE = re.compile(r"^[a-f0-9]{64}$")
KEY_RE = re.compile(r"^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})(?: [^\r\n]*)?$")
WIRE_PREFIX = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"


class Blocked(ValueError):
    pass


def validate_manifest(raw: dict) -> tuple[str, str, str]:
    if not isinstance(raw, dict) or set(raw) != {"schema", "node", "ip", "nonce"}:
        raise Blocked("invalid fresh-VM bootstrap schema")
    if type(raw["schema"]) is not int or raw["schema"] != 2:
        raise Blocked("unsupported bootstrap schema")
    name = raw["node"]
    if not isinstance(name, str):
        raise Blocked("invalid node")
    match = NAME_RE.fullmatch(name)
    if not match or raw["ip"] != "10.78.0." + match.group(1):
        raise Blocked("node/IP outside the approved disposable range")
    nonce = raw["nonce"]
    if not isinstance(nonce, str) or not NONCE_RE.fullmatch(nonce):
        raise Blocked("invalid per-VM provisioning nonce")
    return name, raw["ip"], nonce


def parse_host_key(text: str) -> bytes:
    if len(text) > 1024 or "\n" in text.strip() or "\r" in text.strip():
        raise Blocked("multiple or oversized SSH public keys")
    match = KEY_RE.fullmatch(text.strip())
    if match is None:
        raise Blocked("only one ED25519 SSH public host key is permitted")
    try:
        wire = base64.b64decode(match.group(1), validate=True)
    except (ValueError, base64.binascii.Error) as exc:
        raise Blocked("invalid SSH host public key") from exc
    if len(wire) != 51 or not wire.startswith(WIRE_PREFIX):
        raise Blocked("invalid ED25519 public key wire format")
    if base64.b64encode(wire).decode("ascii").rstrip("=") != match.group(1).rstrip("="):
        raise Blocked("noncanonical SSH public key")
    return wire


def build_value(config: dict, public_key: str) -> str:
    name, ip, nonce = validate_manifest(config)
    wire = parse_host_key(public_key)
    fp = "SHA256:" + base64.b64encode(hashlib.sha256(wire).digest()).decode("ascii").rstrip("=")
    value = {
        "schema": 1,  # compatible with host-side KVP identity parser
        "node": name, "ip": ip, "nonce": nonce,
        "publicKey": "ssh-ed25519 " + base64.b64encode(wire).decode("ascii"),
        "fingerprint": fp,
    }
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def encode_record(name: str, value: str) -> bytes:
    k = name.encode("ascii")
    v = value.encode("ascii")
    if not k or len(k) >= 512 or not v or len(v) >= 2048 or b"\x00" in k or b"\x00" in v:
        raise Blocked("invalid fixed-size Hyper-V KVP record")
    return k.ljust(512, b"\x00") + v.ljust(2048, b"\x00")


def decode_records(blob: bytes) -> list[tuple[str, str]]:
    if len(blob) % RECORD:
        raise Blocked("incomplete or corrupt daemon KVP pool")
    result = []
    for i in range(0, len(blob), RECORD):
        item = blob[i:i + RECORD]
        try:
            result.append((
                item[:512].split(b"\x00", 1)[0].decode("utf-8"),
                item[512:].split(b"\x00", 1)[0].decode("utf-8"),
            ))
        except UnicodeDecodeError as exc:
            raise Blocked("invalid existing KVP pool encoding") from exc
    return result


def publish(pool: Path, value: str, *, fixture: bool = False) -> str:
    if not sys.platform.startswith("linux") or os.name != "posix":
        raise Blocked("KVP publication requires Linux")
    if not fixture and pool not in POOLS:
        raise Blocked("unexpected KVP pool path")
    if pool.is_symlink() or not pool.is_file():
        raise Blocked("KVP pool missing or symlinked")
    fd = os.open(pool, os.O_RDWR | os.O_NOFOLLOW)
    try:
        with os.fdopen(fd, "r+b", buffering=0) as stream:
            meta = os.fstat(stream.fileno())
            if not stat.S_ISREG(meta.st_mode) or meta.st_size > POOL_MAX or meta.st_nlink != 1:
                raise Blocked("unsafe daemon KVP pool")
            if not fixture and meta.st_uid != 0:
                raise Blocked("daemon KVP pool not root-owned")
            fcntl.lockf(stream.fileno(), fcntl.LOCK_EX)
            try:
                raw = stream.read(POOL_MAX + 1)
                if len(raw) > POOL_MAX:
                    raise Blocked("oversized daemon KVP pool")
                entries = decode_records(raw)
                matches = [data for k, data in entries if k == KVP_KEY]
                if len(matches) > 1:
                    raise Blocked("duplicate guest identity records")
                if matches:
                    if matches[0] != value:
                        raise Blocked("KVP identity collision or changed host key")
                    return "UNCHANGED"
                if len(raw) + RECORD > POOL_MAX:
                    raise Blocked("daemon KVP pool lacks capacity")
                record = encode_record(KVP_KEY, value)
                stream.seek(0, os.SEEK_END)
                if stream.write(record) != len(record):
                    raise Blocked("short KVP record append")
                stream.flush()
                os.fsync(stream.fileno())
                return "CREATED"
            finally:
                fcntl.lockf(stream.fileno(), fcntl.LOCK_UN)
    except OSError as exc:
        raise Blocked("cannot safely access KVP daemon pool") from exc


def root_owned_file(path: Path, limit: int) -> str:
    if path.is_symlink() or not path.is_file():
        raise Blocked("missing or symlinked guest input")
    meta = path.stat()
    if meta.st_uid != 0 or meta.st_size > limit or meta.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise Blocked("guest input ownership or permissions invalid")
    return path.read_text(encoding="ascii")


def prepare(config_path: Path = CONFIG, key_path: Path = PUBKEY) -> tuple[Path, str]:
    if os.geteuid() != 0 or not sys.platform.startswith("linux"):
        raise Blocked("root Linux guest required")
    config = json.loads(root_owned_file(config_path, 1024))
    name, _, _ = validate_manifest(config)
    if os.uname().nodename != name:
        raise Blocked("guest hostname disagrees with seed")
    release = Path("/etc/os-release").read_text(encoding="ascii")
    if not re.search(r'^ID=ubuntu$', release, re.MULTILINE) or not re.search(
        r'^VERSION_ID="?26\.04"?$', release, re.MULTILINE
    ):
        raise Blocked("unsupported guest Ubuntu release")
    if subprocess.run(["systemd-detect-virt"], capture_output=True, text=True).stdout.strip() != "microsoft":
        raise Blocked("guest is not Hyper-V")
    if any(Path(p).exists() for p in (
        "/etc/kubernetes/admin.conf", "/etc/kubernetes/kubelet.conf",
        "/etc/kubernetes/bootstrap-kubelet.conf", "/var/lib/kubelet/config.yaml"
    )):
        raise Blocked("existing Kubernetes node cannot publish fresh identity")
    daemon = subprocess.run(["systemctl", "is-active", "--quiet", "hv-kvp-daemon.service"])
    if daemon.returncode != 0:
        raise Blocked("Hyper-V KVP daemon not active")
    if not Path("/dev/vmbus/hv_kvp").is_char_device():
        raise Blocked("guest KVP VMBus device not present")
    paths = [p for p in POOLS if p.is_file() and not p.is_symlink()]
    if len(paths) != 1:
        raise Blocked("expected exactly one pre-existing daemon guest-to-host KVP pool")
    return paths[0], build_value(config, root_owned_file(key_path, 1024))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("plan", "publish"), required=True)
    parser.add_argument("--approval")
    args = parser.parse_args(argv)
    try:
        if args.mode == "publish" and args.approval != APPROVAL:
            raise Blocked("explicit first-boot publisher approval missing")
        pool, value = prepare()
        if args.mode == "plan":
            # No guest KVP pool writes in PLAN.
            records = decode_records(pool.read_bytes())
            matches = [v for k, v in records if k == KVP_KEY]
            if len(matches) > 1 or (matches and matches[0] != value):
                raise Blocked("existing conflicting guest identity record")
            print("FIRSTBOOT_KVP_PLAN_READY: no host SSH trust established")
            return 0
        status = publish(pool, value)
        print("FIRSTBOOT_KVP_PUBLICATION_" + status + ": host must verify through Hyper-V CIM")
        return 0
    except (OSError, UnicodeError, json.JSONDecodeError, Blocked) as exc:
        print("BLOCKED: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
