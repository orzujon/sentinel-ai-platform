#!/usr/bin/env python3
"""Read-only Ubuntu Hyper-V KVP prerequisites, safe on running Kubernetes VMs.

Never opens KVP pools for writing or exposes private SSH host keys.
"""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess


POOL_CANDIDATES = (
    Path("/var/opt/hyperv/.kvp_pool_1"),
    Path("/var/lib/hyperv/.kvp_pool_1"),
)
HOST_PUBLIC = Path("/etc/ssh/ssh_host_ed25519_key.pub")


def probe_paths(pool_candidates=POOL_CANDIDATES, public_key=HOST_PUBLIC) -> dict:
    found = [str(p) for p in pool_candidates if p.is_file()]
    return {
        "poolCandidates": found,
        "guestPoolAccessible": len(found) == 1,
        "hostPublicKeyPresent": public_key.is_file(),
        "hostPrivateKeyAccessed": False,
        "poolModified": False,
    }


def daemon_status() -> dict:
    if not shutil.which("systemctl"):
        return {"service": "unavailable", "active": False}
    for service in ("hv-kvp-daemon.service", "hypervkvpd.service"):
        try:
            result = subprocess.run(
                ["systemctl", "is-active", service], capture_output=True,
                text=True, timeout=5, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        if result.returncode == 0 and result.stdout.strip() == "active":
            return {"service": service, "active": True}
    return {"service": "not-detected", "active": False}


def main() -> int:
    result = probe_paths()
    result.update(daemon_status())
    result["status"] = ("DISCOVERED" if result["guestPoolAccessible"] and
                        result["hostPublicKeyPresent"] and result["active"]
                        else "NEEDS_REVIEW")
    print(json.dumps(result, sort_keys=True))
    print("READ_ONLY: no SSH trust, VM or KVP pool data was modified")
    return 0 if result["status"] == "DISCOVERED" else 2


if __name__ == "__main__":
    raise SystemExit(main())
