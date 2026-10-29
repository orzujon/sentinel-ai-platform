#!/usr/bin/env python3
"""Render a PRIVATE Ansible inventory from an immutable private configuration commit.

This is a management-host helper. It does not connect to hosts, download images,
resolve secrets, change a VM, or print environment inventory to the console.
"""
from __future__ import annotations

import argparse
import yaml
import os
import shlex
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "config"))
from plan import ConfigError, parse_yaml, read_pinned_config, validate  # noqa: E402


def build_inventory(validated_spec: dict, *, known_hosts_file: Path | None = None) -> dict:
    """Build Ansible data using *only* the schema-validated private config."""
    grouped = {"control-plane": {}, "worker": {}}
    for machine in validated_spec["vms"]:
        hostname = machine["name"]
        group = machine["role"]
        ssh_args = (
            "-o BatchMode=yes -o PasswordAuthentication=no "
            "-o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes "
            "-o UpdateHostKeys=no"
        )
        if known_hosts_file is not None:
            ssh_args += (
                " -o UserKnownHostsFile=" + shlex.quote(str(known_hosts_file))
                + " -o GlobalKnownHostsFile=/dev/null"
            )
        grouped[group][hostname] = {
            "ansible_host": machine["staticIP"],
            "ansible_user": validated_spec["identity"]["username"],
            "ansible_connection": "ssh",
            "ansible_python_interpreter": "/usr/bin/python3",
            "ansible_ssh_common_args": ssh_args,
            "sentinel_expected_hostname": hostname,
        }
    # Native Ansible YAML inventory, not a dynamic inventory script.
    return {
        "all": {
            "children": {
                "sentinel_sandbox": {
                    "children": {
                        "sentinel_control_plane": {"hosts": grouped["control-plane"]},
                        "sentinel_workers": {"hosts": grouped["worker"]},
                    }
                }
            }
        }
    }


def save_private_inventory(contents: dict, revision: str, environment: str, *, label: str = "inventory") -> Path:
    """Write only in the operator's private state directory; never in Git."""
    root = Path.home() / ".local" / "state" / "sentinel"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name != "nt":
        os.chmod(root, 0o700)
    if label not in {"inventory", "stage4"}:
        raise ValueError("Unsupported inventory type")
    path = root / f"{label}-{environment}-{revision[:12]}.yml"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        yaml.safe_dump(contents, output, sort_keys=True)
    return path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Private, read-only Stage 4 Ansible inventory")
    parser.add_argument("--config-repo", required=True, help="Already authenticated local private Git clone")
    parser.add_argument("--revision", required=True, help="Full immutable 40-character Git commit")
    parser.add_argument("--environment", required=True, help="Environment key")
    args = parser.parse_args(argv)
    try:
        cfg = parse_yaml(read_pinned_config(args.config_repo, args.revision, args.environment))
        _, spec = validate(cfg, args.environment)
        result = build_inventory(spec)
        output = save_private_inventory(result, args.revision.lower(), args.environment)
        print(f"INVENTORY_READY: {len(spec['vms'])} targets")
        print(f"Private inventory: {output}")
        print("No SSH, remote commands, VM mutation or secret lookup performed.")
        return 0
    except (OSError, ConfigError, FileExistsError) as exc:
        message = str(exc) if isinstance(exc, ConfigError) else (
            "Cannot create private inventory. Existing files are never overwritten."
        )
        print(f"BLOCKED: {message}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
