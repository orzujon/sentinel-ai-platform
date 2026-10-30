#!/usr/bin/env python3
"""Stage 4.1 management runner: derive trust from existing keys, then read-only SSH checks.

Never trusts keys fetched from unverified remote servers and never modifies VMs.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render_inventory import build_inventory, save_private_inventory
from render_inventory import parse_yaml, read_pinned_config, validate


# Deliberately pinned: available on both guests in the 2026-10-30 discovery.
# A version change requires a reviewed source-code change, not a CLI override.
BASELINE_CONTAINERD_VERSION = "2.2.2-0ubuntu1.2"
APPLY_APPROVAL = "APPLY_SENTINEL_STAGE42_TO_SANDBOX"


class Stage4Blocked(Exception):
    pass


def trusted_entries(known_hosts: Path, address: str) -> list[str]:
    """Read entries already trusted by another local SSH client, including hashes."""
    if not known_hosts.is_file():
        raise Stage4Blocked("The existing trusted known_hosts file is missing")
    result = subprocess.run(
        ["ssh-keygen", "-F", address, "-f", str(known_hosts)],
        capture_output=True, text=True, timeout=10, check=False,
    )
    if result.returncode != 0:
        raise Stage4Blocked("A configured host has no previously trusted SSH host key")
    lines = [x.strip() for x in result.stdout.splitlines()
             if x.strip() and not x.lstrip().startswith("#")]
    if not lines:
        raise Stage4Blocked("No usable trusted SSH host-key entries were found")
    for line in lines:
        parts = line.split()
        if len(parts) < 3 or parts[0].startswith("@"):
            raise Stage4Blocked("Unsupported or revoked known_hosts record")
        if not parts[1].startswith(("ssh-", "ecdsa-sha2-", "sk-")):
            raise Stage4Blocked("Unrecognised trusted SSH host-key algorithm")
        if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", parts[2]):
            raise Stage4Blocked("Malformed SSH host-key data")
    return lines


def persist_immutable(path: Path, content: str) -> None:
    """Create once; reject conflicting trust on later runs instead of overwriting it."""
    if path.is_symlink():
        raise Stage4Blocked("Trusted host-key store is a symlink")
    if path.exists():
        if not path.is_file() or path.read_text(encoding="utf-8") != content:
            raise Stage4Blocked("Previously pinned host keys differ; review required")
        if os.name != "nt" and (path.stat().st_mode & 0o077):
            raise Stage4Blocked("Trusted host-key store permissions are too open")
        return

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)


def prepare_host_trust(addresses: list[str], known_hosts: Path,
                       destination: Path) -> None:
    """Pin only keys for requested addresses from the operator's existing store."""
    if not addresses or len(addresses) != len(set(addresses)):
        raise Stage4Blocked("Unexpected or duplicate target IPs")
    all_entries = []
    for address in addresses:
        all_entries.extend(trusted_entries(known_hosts, address))
    # Do not include unrelated Windows known_hosts entries in the WSL trust store.
    body = "\n".join(dict.fromkeys(all_entries)) + "\n"
    persist_immutable(destination, body)


def parse_apt_candidate(policy: str) -> str | None:
    """Interpret the actual apt-cache policy text, never a Jinja fallback."""
    if not isinstance(policy, str) or len(policy) > 120_000:
        return None
    matches = re.findall(r"(?m)^\s*Candidate:\s*(\S+)\s*$", policy)
    if len(matches) != 1:
        return None
    version = matches[0]
    if version.lower() in {"(none)", "none"}:
        return None
    if not re.fullmatch(r"[A-Za-z0-9:~+._-]{1,160}", version):
        return None
    return version


def checked_command(args: list[str], *, stage: str) -> None:
    outcome = subprocess.run(args, check=False)
    if outcome.returncode:
        raise Stage4Blocked(f"{stage} failed (exit {outcome.returncode})")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Stage 4.1 verified Ansible readiness")
    parser.add_argument("--config-repo", required=True)
    parser.add_argument("--revision", required=True, help="Pinned 40-character commit SHA")
    parser.add_argument("--environment", required=True)
    parser.add_argument("--trusted-known-hosts", required=True,
                        help="Existing, independently accepted Windows OpenSSH known_hosts via WSL path")
    parser.add_argument(
        "--discover-baseline",
        action="store_true",
        help="Run the Stage 4.2 read-only Ubuntu/containerd prerequisites inspection"
    )
    parser.add_argument(
        "--plan-baseline", action="store_true",
        help="Read-only proposed changes for the pinned containerd node baseline"
    )
    parser.add_argument(
        "--apply-baseline", action="store_true",
        help="Change only verified sandbox guests after explicit approval"
    )
    parser.add_argument(
        "--approval-token", default=None,
        help="Required literal approval phrase when using --apply-baseline"
    )
    args = parser.parse_args(argv)

    try:
        if args.plan_baseline and args.apply_baseline:
            raise Stage4Blocked("Choose plan or apply, not both")
        if args.apply_baseline:
            if args.approval_token != APPLY_APPROVAL:
                raise Stage4Blocked("Explicit Stage 4.2 sandbox apply approval is missing")
        elif args.approval_token is not None:
            raise Stage4Blocked("Approval token only belongs to an apply run")
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", args.environment):
            raise Stage4Blocked("Invalid environment name")
        if not re.fullmatch(r"[0-9a-fA-F]{40}", args.revision):
            raise Stage4Blocked("Full immutable config commit SHA required")

        cfg = parse_yaml(read_pinned_config(args.config_repo, args.revision, args.environment))
        _, spec = validate(cfg, args.environment)
        if spec.get("provisioningEnabled", False):
            raise Stage4Blocked("Stage 4.1 only accepts provisioning-disabled configurations")
        machines = spec["vms"]
        state = Path.home() / ".local" / "state" / "sentinel"
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        if os.name != "nt":
            os.chmod(state, 0o700)
        trust_path = state / f"known-hosts-{args.environment}-{args.revision[:12]}.txt"
        prepare_host_trust([m["staticIP"] for m in machines],
                           Path(args.trusted_known_hosts), trust_path)
        print("TRUST_READY: verified existing Windows host-key records for all targets",
              flush=True)
        inventory = build_inventory(spec, known_hosts_file=trust_path)
        inventory_path = state / f"stage4-{args.environment}-{args.revision[:12]}.yml"
        if inventory_path.is_file():
            import yaml
            if yaml.safe_load(inventory_path.read_text(encoding="utf-8")) != inventory:
                raise Stage4Blocked("Pinned inventory differs from current private configuration")
        else:
            inventory_path = save_private_inventory(
                inventory, args.revision.lower(), args.environment, label="stage4"
            )
        print(f"INVENTORY_READY: {len(machines)} validated targets", flush=True)
        playbook = Path(__file__).resolve().parent / "playbooks" / "00-readiness.yml"
        checked_command(["ansible-playbook", "-i", str(inventory_path), "--syntax-check", str(playbook)],
                        stage="Playbook syntax check")
        checked_command(["ansible-playbook", "-i", str(inventory_path), str(playbook)],
                        stage="Read-only guest readiness")
        if args.discover_baseline or args.plan_baseline or args.apply_baseline:
            discovery = Path(__file__).resolve().parent / "playbooks" / "10-baseline-discovery.yml"
            checked_command(
                ["ansible-playbook", "-i", str(inventory_path), "--syntax-check",
                 str(discovery)],
                stage="Baseline discovery syntax check"
            )
            report_dir = Path(tempfile.mkdtemp(
                prefix=f"baseline-{args.environment}-{args.revision[:12]}-",
                dir=state,
            ))
            checked_command(
                ["ansible-playbook", "-i", str(inventory_path),
                 "-e", json.dumps({"sentinel_report_root": str(report_dir)}),
                 str(discovery)],
                stage="Stage 4.2 baseline discovery"
            )
            required_fields = {
                "containerdPolicyRaw", "containerdStablePolicyRaw",
                "aptCacheStats", "containerdInstalled",
                "runtimeConfigExists", "runtimeService",
                "swapEntries", "ipv4Forwarding", "kernel",
                "distribution", "distributionVersion", "architecture",
            }
            candidates = []
            missing_candidates = 0
            print("\nSENTINEL BASELINE DISCOVERY — READ ONLY", flush=True)
            for index, machine in enumerate(machines, start=1):
                report_path = report_dir / f"{machine['name']}.json"
                if not report_path.is_file() or report_path.is_symlink():
                    raise Stage4Blocked("A required private per-node report is missing")
                data = json.loads(report_path.read_text(encoding="utf-8"))
                if not isinstance(data, dict) or not required_fields.issubset(data):
                    raise Stage4Blocked("The baseline report is incomplete")
                candidate = parse_apt_candidate(data["containerdPolicyRaw"])
                alternate = parse_apt_candidate(data["containerdStablePolicyRaw"])
                if candidate is None:
                    missing_candidates += 1
                else:
                    candidates.append(candidate)
                if args.plan_baseline or args.apply_baseline:
                    if candidate != BASELINE_CONTAINERD_VERSION:
                        raise Stage4Blocked("Containerd candidate differs from the reviewed version pin")
                    if data["swapEntries"] != 0:
                        raise Stage4Blocked("Active guest swap must be disabled before baseline apply")
                    if data["containerdInstalled"] not in ("not-installed", BASELINE_CONTAINERD_VERSION):
                        raise Stage4Blocked("Existing containerd version differs from pinned package")
                    if data["runtimeConfigExists"] and data["containerdInstalled"] == "not-installed":
                        raise Stage4Blocked("Unmanaged runtime config found before containerd installation")
                print(
                    f"Node {index}/{len(machines)}: "
                    f"Ubuntu {data['distributionVersion']} | "
                    f"containerd candidate {candidate or 'UNAVAILABLE'} | "
                    f"containerd-stable alternative {alternate or 'UNAVAILABLE'} | "
                    f"installed {data['containerdInstalled']} | "
                    f"config exists {data['runtimeConfigExists']} | "
                    f"service {data['runtimeService']} | "
                    f"swap {data['swapEntries']} | "
                    f"forwarding {data['ipv4Forwarding']}",
                    flush=True,
                )
            if missing_candidates:
                print(f"PRIVATE_REPORT: {report_dir}", flush=True)
                raise Stage4Blocked(
                    "APT reports no installable containerd candidate on one or more nodes. "
                    "Inspect local APT metadata and repository sources; do not install or refresh packages automatically."
                )
            if len(set(candidates)) != 1:
                raise Stage4Blocked("Different containerd candidates found across sandbox nodes")
            print(f"PRIVATE_REPORT: {report_dir}", flush=True)
            print("STAGE42_DISCOVERED: all guests inspected; remote changes=0", flush=True)
            if args.plan_baseline or args.apply_baseline:
                apply_playbook = (
                    Path(__file__).resolve().parent
                    / "playbooks" / "20-containerd-baseline.yml"
                )
                checked_command(
                    ["ansible-playbook", "-i", str(inventory_path),
                     "--syntax-check", str(apply_playbook)],
                    stage="Pinned baseline syntax check"
                )
                if args.plan_baseline:
                    print(
                        f"PLAN_ONLY: proposed containerd {BASELINE_CONTAINERD_VERSION} "
                        f"on {len(machines)} validated sandbox VMs", flush=True
                    )
                    print(
                        "Would install pinned package and dependencies, persist/load "
                        "overlay + br_netfilter, enable forwarding, configure systemd "
                        "cgroups and CRI, then enable/verify containerd.", flush=True
                    )
                    print(
                        "NO changes applied. This is an impact preview, not a guarantee "
                        "about all installation side-effects.", flush=True
                    )
                else:
                    print(
                        f"APPLY_APPROVED: pinned containerd {BASELINE_CONTAINERD_VERSION} "
                        f"to {len(machines)} isolated sandbox VMs; changing guest state",
                        flush=True
                    )
                    checked_command(
                        ["ansible-playbook", "-i", str(inventory_path),
                         "-e", json.dumps({
                             "sentinel_containerd_version": BASELINE_CONTAINERD_VERSION,
                             "sentinel_apply_approved": True,
                         }), str(apply_playbook)],
                        stage="Stage 4.2 explicit-approval containerd baseline apply"
                    )
                    print(
                        "STAGE42_APPLIED: review Ansible recap above and rerun for "
                        "idempotence verification", flush=True
                    )
        print("STAGE4_READY: all guest checks passed; no provisioning performed")
        return 0
    except (Stage4Blocked, OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
