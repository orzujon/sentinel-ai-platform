#!/usr/bin/env python3
"""Stage 4.1 management runner: derive trust from existing keys, then read-only SSH checks.

Never trusts keys fetched from unverified remote servers and never modifies VMs.
"""
from __future__ import annotations

import argparse
import json
import ipaddress
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
REBOOT_APPROVAL = "REBOOT_SENTINEL_STAGE42_SANDBOX"


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


# Stage 4.3 discovery is intentionally independent of the baseline apply.
# The proposed Pod and Service CIDRs are reviewed candidates, NOT deployed state.
STAGE43_POD_CIDR = ipaddress.ip_network("10.244.0.0/16")
STAGE43_SERVICE_CIDR = ipaddress.ip_network("10.96.0.0/12")
STAGE43_CONTROL_PORTS = {6443, 2379, 2380, 10250, 10257, 10259}


def parse_listen_ports(ss_output: str) -> set[int]:
    """Parse only the local endpoint from ss -H -ltn, never infer remote ports."""
    if not isinstance(ss_output, str) or len(ss_output) > 120_000:
        raise Stage4Blocked("Invalid local TCP socket inspection output")
    found: set[int] = set()
    for line in ss_output.splitlines():
        columns = line.split()
        if len(columns) < 5 or columns[0] != "LISTEN":
            raise Stage4Blocked("Unexpected listening socket record")
        local = columns[3]
        port = local.rsplit(":", 1)[-1]
        if not port.isdigit() or not 0 <= int(port) <= 65535:
            raise Stage4Blocked("Unexpected local TCP port")
        found.add(int(port))
    return found


def parse_ip_routes(route_data: str) -> list[ipaddress.IPv4Network]:
    if not isinstance(route_data, str) or len(route_data) > 120_000:
        raise Stage4Blocked("Invalid IPv4 route inspection output")
    entries = json.loads(route_data)
    if not isinstance(entries, list):
        raise Stage4Blocked("IPv4 routing table must be a JSON list")
    networks = []
    for route in entries:
        if not isinstance(route, dict):
            raise Stage4Blocked("Malformed IPv4 route")
        dst = route.get("dst", "default")
        if dst == "default":
            continue
        if not isinstance(dst, str):
            raise Stage4Blocked("Malformed IPv4 route destination")
        networks.append(ipaddress.ip_network(dst, strict=False))
    return networks


def parse_host_addresses(address_data: str) -> set[ipaddress.IPv4Address]:
    if not isinstance(address_data, str) or len(address_data) > 120_000:
        raise Stage4Blocked("Invalid guest interface inspection output")
    interfaces = json.loads(address_data)
    if not isinstance(interfaces, list):
        raise Stage4Blocked("Guest IP interfaces must be a JSON list")
    addresses: set[ipaddress.IPv4Address] = set()
    for interface in interfaces:
        if not isinstance(interface, dict) or not isinstance(interface.get("addr_info"), list):
            raise Stage4Blocked("Malformed guest interface record")
        for info in interface["addr_info"]:
            if not isinstance(info, dict):
                raise Stage4Blocked("Malformed guest IP address record")
            if info.get("family") == "inet":
                addresses.add(ipaddress.IPv4Address(info["local"]))
    return addresses


def check_kubernetes_discovery_report(data: dict, *, target_ip: str,
                                     protected_networks: list[str]) -> dict:
    """Fail closed on accidental cluster reuse, broken containerd or CIDR collisions."""
    required = {
        "distribution", "distributionVersion", "architecture", "k8sMarkers",
        "kubeadmPolicyRaw", "kubeletPolicyRaw", "kubectlPolicyRaw",
        "kubeadmInstalled", "kubeletInstalled", "kubectlInstalled",
        "containerdInstalled", "containerdService", "criPluginsRaw",
        "criSocketExists", "ipv4Forwarding", "swapEntries",
        "addressesRaw", "routesRaw", "tcpListenersRaw", "kubeletService",
    }
    if not isinstance(data, dict) or not required.issubset(data):
        raise Stage4Blocked("Incomplete Stage 4.3 discovery report")
    if (
        data["distribution"] != "Ubuntu"
        or data["distributionVersion"] != "26.04"
        or data["architecture"] != "x86_64"
    ):
        raise Stage4Blocked("Kubernetes guest platform differs from approved Ubuntu")
    markers = data["k8sMarkers"]
    if not isinstance(markers, list) or len(markers) != 5 or not all(isinstance(x, bool) for x in markers):
        raise Stage4Blocked("Untrusted Kubernetes marker report")
    if any(markers):
        raise Stage4Blocked("Existing Kubernetes cluster markers detected; do not reinitialize")
    if any(data[name] != "not-installed" for name in ("kubeadmInstalled", "kubeletInstalled", "kubectlInstalled")):
        raise Stage4Blocked("Kubernetes packages already installed; manual review required")
    if data["containerdInstalled"] != BASELINE_CONTAINERD_VERSION:
        raise Stage4Blocked("Containerd package no longer matches pinned Stage 4.2 baseline")
    if (
        data["containerdService"] != "active"
        or data["criSocketExists"] is not True
        or "io.containerd.cri.v1" not in data["criPluginsRaw"]
    ):
        raise Stage4Blocked("Container runtime or CRI is not ready")
    if data["swapEntries"] != 0 or str(data["ipv4Forwarding"]) != "1":
        raise Stage4Blocked("Swap or IP forwarding differs from approved baseline")
    if data["kubeletService"] == "active":
        raise Stage4Blocked("Unexpected active kubelet service")
    if ipaddress.IPv4Address(target_ip) not in parse_host_addresses(data["addressesRaw"]):
        raise Stage4Blocked("Expected private VM IPv4 address is not configured")
    routes = parse_ip_routes(data["routesRaw"])
    cidrs = [ipaddress.ip_network(n) for n in protected_networks]
    if STAGE43_POD_CIDR.overlaps(STAGE43_SERVICE_CIDR):
        raise Stage4Blocked("Pod and Service CIDRs overlap")
    for network in routes + cidrs:
        if network.overlaps(STAGE43_POD_CIDR) or network.overlaps(STAGE43_SERVICE_CIDR):
            raise Stage4Blocked("Proposed Kubernetes Pod/Service CIDR overlaps an existing network")
    occupied = parse_listen_ports(data["tcpListenersRaw"]) & STAGE43_CONTROL_PORTS
    if occupied:
        raise Stage4Blocked("Kubernetes reserved TCP port is already listening: " + str(sorted(occupied)))
    package_candidates = {
        name: parse_apt_candidate(data[name + "PolicyRaw"])
        for name in ("kubeadm", "kubelet", "kubectl")
    }
    return package_candidates


# Pinned minor-scoped repository; patch is a candidate until signed APT
# metadata confirms the *exact* distro package version on both nodes.
STAGE432_MINOR = "v1.37"
STAGE432_PATCH_CANDIDATE = "v1.37.1"
STAGE432_REPO_URL = "https://pkgs.k8s.io/core:/stable:/v1.37/deb/"
REPO_BOOTSTRAP_APPROVAL = "CONFIGURE_SENTINEL_STAGE432_K8S_REPO"


def validate_kubernetes_package_source_plan(data: dict) -> dict:
    fields = {
        "aptSourceExists", "aptKeyringExists", "caCertificatesInstalled",
        "curlInstalled", "gpgInstalled", "packageHolds", "repoTlsReachable",
    }
    if not isinstance(data, dict) or set(data) != fields:
        raise Stage4Blocked("Unexpected Kubernetes APT source plan report")
    for name in fields - {"packageHolds"}:
        if type(data[name]) is not bool:
            raise Stage4Blocked("Malformed Kubernetes APT source inspection")
    if not isinstance(data["packageHolds"], list) or not all(
        isinstance(x, str) and len(x) < 150 for x in data["packageHolds"]
    ):
        raise Stage4Blocked("Malformed APT package hold inspection")
    if data["aptSourceExists"] or data["aptKeyringExists"]:
        raise Stage4Blocked("Kubernetes APT source/keyring already exists; review before overwriting")
    if not data["repoTlsReachable"]:
        raise Stage4Blocked("Cannot reach the official HTTPS Kubernetes package source")
    if not data["caCertificatesInstalled"]:
        raise Stage4Blocked("Ubuntu CA trust bundle unavailable for signed source")
    if any(x in {"kubeadm", "kubelet", "kubectl"} for x in data["packageHolds"]):
        raise Stage4Blocked("Existing Kubernetes package holds require manual investigation")
    return {
        "curlAvailable": data["curlInstalled"],
        "gpgAvailable": data["gpgInstalled"],
    }


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
    parser.add_argument(
        "--reboot-validate", action="store_true",
        help="Reboot only explicitly approved sandbox guests, one at a time, verifying persistence"
    )
    parser.add_argument(
        "--reboot-approval-token", default=None,
        help="Separate approval phrase required for disruptive sandbox reboots"
    )
    parser.add_argument(
        "--discover-kubernetes",
        action="store_true",
        help="Stage 4.3.1 Kubernetes readiness, networking and package metadata inspection; guest read-only"
    )
    parser.add_argument(
        "--plan-kubernetes-packages",
        action="store_true",
        help="Read-only Stage 4.3.2 signed source reachability and package plan"
    )
    parser.add_argument(
        "--configure-kubernetes-repo",
        action="store_true",
        help="Approved signed v1.37 APT repository setup ONLY; does not install Kubernetes"
    )
    parser.add_argument(
        "--repository-approval-token", default=None,
        help="Separate approval for changing only Kubernetes APT repository and cache"
    )
    parser.add_argument("--plan-kubernetes-install", action="store_true",
                        help="Read-only pinned Kubernetes package installation simulation")
    parser.add_argument("--install-kubernetes-packages", action="store_true",
                        help="Explicitly approved pinned Kubernetes package installation")
    parser.add_argument("--install-approval-token", default=None)
    parser.add_argument("--plan-control-plane", action="store_true",
                        help="Validate kubeadm initialization config without modifying guests")
    parser.add_argument("--init-control-plane", action="store_true",
                        help="Explicitly approved first-time control-plane init")
    parser.add_argument("--control-plane-approval-token", default=None)
    parser.add_argument("--plan-flannel", action="store_true",
                        help="Read-only Stage 4.3.4 control-plane API and pinned Flannel release plan")
    parser.add_argument("--apply-flannel", action="store_true",
                        help="Explicitly approved SHA256-gated Flannel deployment")
    parser.add_argument("--flannel-approval-token", default=None)
    parser.add_argument("--flannel-sha256", default=None)
    parser.add_argument("--reconcile", action="store_true",
                        help="Single desired-state verification and Flannel reconciliation")
    parser.add_argument("--reconcile-approval-token", default=None)
    args = parser.parse_args(argv)

    try:
        if sum((
            bool(args.plan_baseline), bool(args.apply_baseline),
            bool(args.reboot_validate), bool(args.discover_kubernetes),
            bool(args.plan_kubernetes_packages), bool(args.configure_kubernetes_repo),
            bool(args.plan_kubernetes_install), bool(args.install_kubernetes_packages),
            bool(args.plan_control_plane), bool(args.init_control_plane),
            bool(args.plan_flannel), bool(args.apply_flannel), bool(args.reconcile),
        )) > 1:
            raise Stage4Blocked("Choose exactly one Stage 4.2 or 4.3 mode")
        if args.reconcile:
            if args.reconcile_approval_token not in (None, "DEPLOY_SENTINEL_LEVEL1_LAB"):
                raise Stage4Blocked("Invalid environment-scoped Level 1 deployment approval")
        elif args.reconcile_approval_token is not None:
            raise Stage4Blocked("Reconcile approval only applies to desired-state reconciliation")
        if args.apply_flannel:
            if args.flannel_approval_token != "APPLY_SENTINEL_STAGE434_FLANNEL_02810":
                raise Stage4Blocked("Missing separate Flannel deployment approval")
            if not args.flannel_sha256 or not re.fullmatch(r"[a-f0-9]{64}", args.flannel_sha256):
                raise Stage4Blocked("Reviewed Flannel SHA256 is required for deployment")
        elif args.flannel_approval_token is not None or args.flannel_sha256 is not None:
            raise Stage4Blocked("Flannel deployment approval and SHA256 only belong in apply mode")
        if args.init_control_plane:
            if args.control_plane_approval_token != "INITIALIZE_SENTINEL_STAGE433_CONTROL_PLANE":
                raise Stage4Blocked("Missing explicit Stage 4.3.3 control-plane approval")
        elif args.control_plane_approval_token is not None:
            raise Stage4Blocked("Control-plane approval token is valid only in init mode")
        if args.install_kubernetes_packages:
            if args.install_approval_token != "INSTALL_SENTINEL_STAGE432_K8S_1372":
                raise Stage4Blocked("Missing separate Kubernetes installation approval")
        elif args.install_approval_token is not None:
            raise Stage4Blocked("Install approval token only valid in install mode")
        if args.configure_kubernetes_repo:
            if args.repository_approval_token != REPO_BOOTSTRAP_APPROVAL:
                raise Stage4Blocked("Separate Stage 4.3.2 repository approval is missing")
        elif args.repository_approval_token is not None:
            raise Stage4Blocked("Repository approval token is only valid in repository configure mode")
        if args.reboot_validate:
            if args.reboot_approval_token != REBOOT_APPROVAL:
                raise Stage4Blocked("Explicit sandbox reboot approval is missing")
        elif args.reboot_approval_token is not None:
            raise Stage4Blocked("Reboot approval token only belongs to a reboot validation run")
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
        if args.discover_baseline or args.plan_baseline or args.apply_baseline or args.reboot_validate:
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
                if args.plan_baseline or args.apply_baseline or args.reboot_validate:
                    if candidate != BASELINE_CONTAINERD_VERSION:
                        raise Stage4Blocked("Containerd candidate differs from the reviewed version pin")
                    if data["swapEntries"] != 0:
                        raise Stage4Blocked("Active guest swap must be disabled before baseline apply")
                    if data["containerdInstalled"] not in ("not-installed", BASELINE_CONTAINERD_VERSION):
                        raise Stage4Blocked("Existing containerd version differs from pinned package")
                    if data["runtimeConfigExists"] and data["containerdInstalled"] == "not-installed":
                        raise Stage4Blocked("Unmanaged runtime config found before containerd installation")
                    if args.reboot_validate:
                        if (
                            data["containerdInstalled"] != BASELINE_CONTAINERD_VERSION
                            or data["runtimeConfigExists"] is not True
                            or data["runtimeService"] != "active"
                            or str(data["ipv4Forwarding"]) != "1"
                        ):
                            raise Stage4Blocked("Sandbox baseline is not fully installed; reboot not permitted")
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
            if args.reboot_validate:
                reboot_playbook = (
                    Path(__file__).resolve().parent
                    / "playbooks" / "30-reboot-persistence.yml"
                )
                checked_command(
                    ["ansible-playbook", "-i", str(inventory_path),
                     "--syntax-check", str(reboot_playbook)],
                    stage="Reboot persistence playbook syntax check"
                )
                print(
                    "REBOOT_APPROVED: both validated isolated sandbox VMs will reboot "
                    "one at a time. No original VMs are targeted.",
                    flush=True,
                )
                checked_command(
                    ["ansible-playbook", "-i", str(inventory_path),
                     "-e", json.dumps({
                         "sentinel_reboot_approved": True,
                         "sentinel_reboot_version": BASELINE_CONTAINERD_VERSION,
                     }), str(reboot_playbook)],
                    stage="Approved Stage 4.2 reboot persistence verification"
                )
                print(
                    "STAGE42_REBOOT_VERIFIED: pinned containerd service, CRI and "
                    "networking survived reboot on all sandbox guests",
                    flush=True,
                )
        if args.reconcile:
            if len(machines) != 2 or {m["role"] for m in machines} != {"control-plane", "worker"}:
                raise Stage4Blocked("Desired-state reconciliation requires the pinned two-node sandbox")
            reconciler = Path(__file__).resolve().parent / "reconcile.py"
            args_reconcile = [sys.executable, str(reconciler), "--inventory", str(inventory_path),
                              "--environment", args.environment,
                              "--mode", "apply" if args.reconcile_approval_token else "plan"]
            if args.reconcile_approval_token:
                args_reconcile.append("--approved")
            checked_command(args_reconcile, stage="Level 1 Flannel desired-state reconciliation")
            print("SENTINEL_RECONCILED: review the private audit and Kubernetes node readiness", flush=True)
        if args.apply_flannel:
            if len(machines) != 2 or {m["role"] for m in machines} != {"control-plane", "worker"}:
                raise Stage4Blocked("Flannel deployment requires pinned two-node sandbox")
            flannel_apply = Path(__file__).resolve().parent / "playbooks" / "110-flannel-release-apply.yml"
            checked_command(["ansible-playbook", "-i", str(inventory_path),
                             "--syntax-check", str(flannel_apply)], stage="Flannel apply syntax")
            checked_command(["ansible-playbook", "-i", str(inventory_path),
                             "-e", json.dumps({"sentinel_flannel_approved": True,
                                               "sentinel_flannel_sha256": args.flannel_sha256}),
                             str(flannel_apply)], stage="Approved pinned Flannel deployment")
            print("STAGE434_FLANNEL_READY", flush=True)
        if args.plan_flannel:
            if len(machines) != 2 or {m["role"] for m in machines} != {"control-plane", "worker"}:
                raise Stage4Blocked("Flannel planning requires pinned control plane and worker")
            flannel = Path(__file__).resolve().parent / "playbooks" / "100-flannel-release-plan.yml"
            checked_command(["ansible-playbook", "-i", str(inventory_path),
                             "--syntax-check", str(flannel)], stage="Flannel release plan syntax")
            checked_command(["ansible-playbook", "-i", str(inventory_path), str(flannel)],
                            stage="Stage 4.3.4 pinned Flannel release inspection")
            print("STAGE434_PLAN_READY: review pinned manifest fingerprint", flush=True)
        if args.plan_control_plane or args.init_control_plane:
            if len(machines) != 2 or {m["role"] for m in machines} != {"control-plane", "worker"}:
                raise Stage4Blocked("Stage 4.3.3 accepts only the two-node pinned sandbox")
            cp = Path(__file__).resolve().parent / "playbooks" / "90-kubeadm-control-plane.yml"
            checked_command(["ansible-playbook", "-i", str(inventory_path),
                             "--syntax-check", str(cp)], stage="Control-plane playbook syntax")
            mode = "apply" if args.init_control_plane else "plan"
            if mode == "apply":
                print("APPROVED STAGE433: initializing only the existing sandbox control plane", flush=True)
            checked_command(["ansible-playbook", "-i", str(inventory_path),
                             "-e", json.dumps({"sentinel_kubeadm_mode": mode,
                                               "sentinel_cp_init_approved": mode == "apply"}),
                             str(cp)], stage="Stage 4.3.3 control-plane " + mode)
            print("STAGE433_" + ("INITIALIZED" if mode == "apply" else "PLAN_READY"), flush=True)
        if args.plan_kubernetes_install or args.install_kubernetes_packages:
            if len(machines) != 2 or {m["role"] for m in machines} != {"control-plane", "worker"}:
                raise Stage4Blocked("Kubernetes package installation requires the pinned two-node sandbox")
            plan = Path(__file__).resolve().parent / "playbooks" / "70-kubernetes-install-plan.yml"
            install = Path(__file__).resolve().parent / "playbooks" / "80-kubernetes-package-install.yml"
            checked_command(["ansible-playbook", "-i", str(inventory_path),
                             "--syntax-check", str(plan)], stage="Kubernetes install plan syntax")
            report_dir = Path(tempfile.mkdtemp(prefix="k8s-install-plan-", dir=state))
            checked_command(["ansible-playbook", "-i", str(inventory_path),
                             "-e", json.dumps({"sentinel_report_root": str(report_dir)}),
                             str(plan)], stage="Read-only Kubernetes package installation simulation")
            for machine in machines:
                report = report_dir / f"{machine['name']}.json"
                if not report.is_file() or report.is_symlink() or (report.stat().st_mode & 0o077):
                    raise Stage4Blocked("Missing or insecure package installation simulation")
                data = json.loads(report.read_text(encoding="utf-8"))
                if set(data) != {"policies", "simulation", "source"} or len(data["policies"]) != 3:
                    raise Stage4Blocked("Incomplete package installation plan")
                if any(parse_apt_candidate(policy) != "1.37.2-1.1" for policy in data["policies"]):
                    raise Stage4Blocked("Pinned Kubernetes candidate differs on a guest")
                simulation = data["simulation"]
                if not isinstance(simulation, str) or not simulation.strip() or re.search(r"(?m)^Rem ", simulation):
                    raise Stage4Blocked("APT simulation empty or proposes package removal")
                print(f"Node {machine['role']}: pinned 1.37.2-1.1 candidates; APT simulation passed", flush=True)
            print(f"PRIVATE_REPORT: {report_dir}", flush=True)
            if args.install_kubernetes_packages:
                checked_command(["ansible-playbook", "-i", str(inventory_path),
                                 "--syntax-check", str(install)], stage="Kubernetes install syntax")
                checked_command(["ansible-playbook", "-i", str(inventory_path),
                                 "-e", json.dumps({"sentinel_k8s_install_approved": True,
                                                   "sentinel_k8s_version": "1.37.2-1.1"}),
                                 str(install)], stage="Approved Kubernetes package installation")
                print("STAGE432_INSTALLED: Kubernetes packages installed and held; cluster not initialized", flush=True)
            else:
                print("STAGE432_INSTALL_PLAN_READY: read-only plan passed; installation requires separate approval", flush=True)
        if args.discover_kubernetes or args.plan_kubernetes_packages or args.configure_kubernetes_repo:
            if len(machines) != 2 or {m["role"] for m in machines} != {"control-plane", "worker"}:
                raise Stage4Blocked("Stage 4.3 accepts exactly one control plane and one worker")
            discovery43 = (
                Path(__file__).resolve().parent
                / "playbooks" / "40-kubernetes-discovery.yml"
            )
            checked_command(
                ["ansible-playbook", "-i", str(inventory_path),
                 "--syntax-check", str(discovery43)],
                stage="Kubernetes discovery syntax check"
            )
            report_dir = Path(tempfile.mkdtemp(
                prefix=f"kubernetes-{args.environment}-{args.revision[:12]}-",
                dir=state,
            ))
            checked_command(
                ["ansible-playbook", "-i", str(inventory_path),
                 "-e", json.dumps({"sentinel_report_root": str(report_dir)}),
                 str(discovery43)],
                stage="Stage 4.3.1 Kubernetes discovery"
            )
            package_status = {}
            print("\\nSENTINEL KUBERNETES DISCOVERY — READ ONLY", flush=True)
            for index, machine in enumerate(machines, start=1):
                report_path = report_dir / f"{machine['name']}.json"
                if not report_path.is_file() or report_path.is_symlink():
                    raise Stage4Blocked("Missing private Kubernetes discovery report")
                if report_path.stat().st_size > 350_000 or (report_path.stat().st_mode & 0o077):
                    raise Stage4Blocked("Private Kubernetes report permissions or size invalid")
                data = json.loads(report_path.read_text(encoding="utf-8"))
                candidates = check_kubernetes_discovery_report(
                    data, target_ip=machine["staticIP"],
                    protected_networks=[
                        spec["network"]["subnet"], *spec["protection"]["subnets"],
                    ],
                )
                package_status[machine["name"]] = candidates
                def shown(candidate: str | None) -> str:
                    return candidate or "NOT_IN_APT_CACHE"
                print(
                    f"Node {index}/{len(machines)} role={machine['role']} | "
                    f"containerd={data['containerdInstalled']} active | "
                    f"swap=0 forwarding=1 | Kubernetes existing=no | "
                    f"kubeadm={shown(candidates['kubeadm'])} "
                    f"kubelet={shown(candidates['kubelet'])} "
                    f"kubectl={shown(candidates['kubectl'])}",
                    flush=True,
                )
            all_candidates = list(package_status.values())
            matching = all_candidates[0] == all_candidates[1]
            installed = all(all(v is not None for v in p.values()) for p in all_candidates)
            if installed and not matching:
                print("PACKAGE_SOURCE_REVIEW: guest Kubernetes APT candidates differ", flush=True)
            elif not installed:
                print("PACKAGE_SOURCE_REVIEW: kubeadm/kubelet/kubectl missing from at least one local APT cache", flush=True)
            else:
                print("PACKAGE_SOURCE_REVIEW: candidates discovered; version/repository review still required", flush=True)
            print(
                f"NETWORK_CANDIDATES: pod={STAGE43_POD_CIDR} "
                f"service={STAGE43_SERVICE_CIDR}; no observed overlap on validated guests",
                flush=True,
            )
            print(f"PRIVATE_REPORT: {report_dir}", flush=True)
            print("STAGE43_DISCOVERED: guests inspected; remote changes=0; no packages installed", flush=True)
            if args.plan_kubernetes_packages or args.configure_kubernetes_repo:
                source_plan = Path(__file__).resolve().parent / "playbooks" / "50-kubernetes-package-source-plan.yml"
                checked_command(
                    ["ansible-playbook", "-i", str(inventory_path),
                     "--syntax-check", str(source_plan)],
                    stage="Stage 4.3.2 package-source plan syntax"
                )
                source_dir = Path(tempfile.mkdtemp(
                    prefix=f"k8s-source-{args.environment}-{args.revision[:12]}-",
                    dir=state,
                ))
                checked_command(
                    ["ansible-playbook", "-i", str(inventory_path),
                     "-e", json.dumps({"sentinel_report_root": str(source_dir)}),
                     str(source_plan)],
                    stage="Stage 4.3.2 read-only package source inspection"
                )
                print("\nSENTINEL STAGE 4.3.2 PACKAGE PLAN — READ ONLY", flush=True)
                for machine in machines:
                    source_file = source_dir / f"{machine['name']}.json"
                    if not source_file.is_file() or source_file.is_symlink():
                        raise Stage4Blocked("Missing package source report")
                    if source_file.stat().st_size > 50_000 or (source_file.stat().st_mode & 0o077):
                        raise Stage4Blocked("Insecure or oversized package source report")
                    source_data = json.loads(source_file.read_text(encoding="utf-8"))
                    tools_status = validate_kubernetes_package_source_plan(source_data)
                    print(
                        f"Node {machine['role']}: official HTTPS reachable | "
                        f"existing Kubernetes source/keyring=no | "
                        f"curl={'ready' if tools_status['curlAvailable'] else 'missing'} "
                        f"gpg={'ready' if tools_status['gpgAvailable'] else 'missing'}",
                        flush=True,
                    )
                print(
                    f"VERSION_PROPOSAL: Kubernetes minor={STAGE432_MINOR} "
                    f"patch candidate={STAGE432_PATCH_CANDIDATE}; exact APT package revision "
                    "NOT YET VERIFIED",
                    flush=True,
                )
                print(f"REPOSITORY_PROPOSAL: {STAGE432_REPO_URL}", flush=True)
                print("PLAN_ONLY: configure verified signed-by keyring, add minor-specific APT repo, "
                      "refresh indexes, confirm exact signed package versions on both nodes, "
                      "approve pinned installation and hold packages in a later step.", flush=True)
                print(f"PRIVATE_REPORT: {source_dir}", flush=True)
                print("STAGE432_PLAN_READY: packages installed=0, guest configuration changes=0", flush=True)
                if args.configure_kubernetes_repo:
                    bootstrap = Path(__file__).resolve().parent / "playbooks" / "60-kubernetes-repository.yml"
                    checked_command(
                        ["ansible-playbook", "-i", str(inventory_path),
                         "--syntax-check", str(bootstrap)],
                        stage="Approved Kubernetes APT repository syntax"
                    )
                    post_dir = Path(tempfile.mkdtemp(
                        prefix=f"k8s-repo-{args.environment}-{args.revision[:12]}-",
                        dir=state,
                    ))
                    print(
                        "APPROVED REPOSITORY SETUP: fingerprint-gated signed APT source and "
                        "package metadata on sandbox only; no Kubernetes installation",
                        flush=True
                    )
                    checked_command(
                        ["ansible-playbook", "-i", str(inventory_path),
                         "-e", json.dumps({
                             "sentinel_repo_bootstrap_approved": True,
                             "sentinel_report_root": str(post_dir),
                         }), str(bootstrap)],
                        stage="Approved Kubernetes repository setup"
                    )
                    observed = []
                    for machine in machines:
                        node_report = post_dir / f"{machine['name']}.json"
                        if not node_report.is_file() or node_report.is_symlink():
                            raise Stage4Blocked("Missing signed Kubernetes package policy evidence")
                        if node_report.stat().st_size > 50_000 or (node_report.stat().st_mode & 0o077):
                            raise Stage4Blocked("Kubernetes package policy evidence is not private")
                        policy_data = json.loads(node_report.read_text(encoding="utf-8"))
                        expected_keys = {"kubeadmPolicyRaw", "kubeletPolicyRaw", "kubectlPolicyRaw"}
                        if not isinstance(policy_data, dict) or set(policy_data) != expected_keys:
                            raise Stage4Blocked("Incomplete signed Kubernetes APT package evidence")
                        available = {
                            name: parse_apt_candidate(policy_data[name + "PolicyRaw"])
                            for name in ("kubeadm", "kubelet", "kubectl")
                        }
                        if any(version is None for version in available.values()):
                            raise Stage4Blocked(
                                "Kubernetes signed APT repository exists but no complete package candidate set; investigate"
                            )
                        if len(set(available.values())) != 1:
                            raise Stage4Blocked(
                                "kubeadm/kubelet/kubectl package versions differ on a node"
                            )
                        observed.append(available)
                        print(
                            f"Node {machine['role']}: signed repo verified | "
                            f"kubeadm={available['kubeadm']} "
                            f"kubelet={available['kubelet']} "
                            f"kubectl={available['kubectl']}",
                            flush=True,
                        )
                    if observed[0] != observed[1]:
                        raise Stage4Blocked("APT package candidates differ between sandbox nodes")
                    if not all(v.startswith("1.37.") for v in observed[0].values()):
                        raise Stage4Blocked("APT package revision is not from the approved v1.37 minor")
                    print(f"PRIVATE_REPORT: {post_dir}", flush=True)
                    print(
                        "STAGE432_REPO_CONFIGURED: signed source verified on both nodes; "
                        "Kubernetes packages installed=0; exact version available for review",
                        flush=True,
                    )
        print("STAGE4_READY: guest readiness checks passed; configuration changes depend on selected mode")
        return 0
    except (Stage4Blocked, OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
