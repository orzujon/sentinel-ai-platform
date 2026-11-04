#!/usr/bin/env python3
"""Explicit fresh-cluster stages. No implicit retries, cleanup or old inventory reuse."""
from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile
import uuid

import yaml

from reconcile import retrieve_verified_release

NODES = {"cp01": "10.78.0.30", "w01": "10.78.0.31"}
ROOT = Path("/mnt/c/Sentinel/FreshCluster/VMs")
POD_CIDR = "10.245.0.0/16"
SERVICE_CIDR = "10.112.0.0/16"
FLANNEL_VERSION = "v0.28.10"
PLAYBOOKS = Path(__file__).resolve().parent / "playbooks"
STAGES = {
    "readiness": "00-readiness.yml",
    "baseline": "20-containerd-baseline.yml",
    "repository": "60-kubernetes-repository.yml",
    "packages": "80-kubernetes-package-install.yml",
    "init": "90-kubeadm-control-plane.yml",
    "cni": "120-reconcile-flannel.yml",
    "join": "130-reconcile-worker.yml",
    "verify": "140-cluster-validate.yml",
    "network-test": "150-active-network.yml",
    "reboot-test": "170-fresh-reboot-persistence.yml",
}
READ_ONLY = {"readiness", "verify"}


class Blocked(ValueError):
    pass


def validate_binding(name: str, manifest: dict, trusted_line: str) -> dict:
    if name not in NODES:
        raise Blocked("Unknown fresh node")
    suffix = NODES[name].rsplit(".", 1)[1]
    expected = {"schema": 3, "purpose": "sentinel-fresh-cluster-v1", "node": name,
                "privateIP": NODES[name], "managementMAC": "02AA780001" + suffix,
                "privateMAC": "02AA780000" + suffix, "kubernetesInstall": False}
    if any(type(manifest.get(k)) is not type(v) or manifest[k] != v for k, v in expected.items()):
        raise Blocked("Fresh manifest scope mismatch")
    if not re.fullmatch(r"[a-f0-9]{64}", manifest.get("nonce", "")):
        raise Blocked("Invalid provisioning nonce")
    if not re.fullmatch(r"[a-f0-9]{64}", manifest.get("sourceImageSHA256", "")):
        raise Blocked("Invalid image pin")
    if uuid.UUID(manifest["vmId"]).int == 0:
        raise Blocked("Empty VM identity")
    fields = trusted_line.strip().split()
    if len(fields) != 3 or fields[:2] != [NODES[name], "ssh-ed25519"] or len(trusted_line.splitlines()) != 1:
        raise Blocked("Only one exact pinned ED25519 host record is allowed")
    wire = base64.b64decode(fields[2], validate=True)
    if len(wire) != 51 or not wire.startswith(b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"):
        raise Blocked("Invalid pinned host key")
    return {**manifest, "trustedLine": " ".join(fields) + "\n"}


def validate_pair(bindings: list[dict]) -> None:
    if len(bindings) != 2 or {b["node"] for b in bindings} != set(NODES):
        raise Blocked("Exactly the fresh pair is required")
    for field in ("vmId", "nonce", "trustedLine"):
        values = [b[field].lower() if field == "vmId" else b[field] for b in bindings]
        if len(set(values)) != 2:
            raise Blocked("Duplicate pair identity: " + field)
    if len({b["trustedLine"].split()[2] for b in bindings}) != 2:
        raise Blocked("Guests share an SSH host key")
    if len({b["sourceImageSHA256"] for b in bindings}) != 1:
        raise Blocked("Pair was built from different source images")


def build_inventory(bindings: list[dict], key: str, trust: Path) -> dict:
    validate_pair(bindings)
    if not re.fullmatch(r"/home/[a-z][a-z0-9_-]*/\.ssh/id_ed25519", key):
        raise Blocked("Unsupported existing WSL user key path")
    ssh_options = shlex.join([
        "-F", "none", "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={trust}",
        "-o", "GlobalKnownHostsFile=/dev/null", "-o", "HostKeyAlgorithms=ssh-ed25519",
        "-o", "UpdateHostKeys=no", "-o", "VerifyHostKeyDNS=no", "-o", "BatchMode=yes",
        "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
        "-o", "PreferredAuthentications=publickey", "-o", "IdentitiesOnly=yes",
        "-o", "IdentityAgent=none", "-o", "ForwardAgent=no", "-o", "ControlMaster=no",
    ])
    hosts = {}
    for b in bindings:
        hosts[b["node"]] = {"ansible_host": b["privateIP"], "ansible_user": "orzu",
            "ansible_ssh_private_key_file": key, "ansible_ssh_common_args": ssh_options,
            "ansible_python_interpreter": "/usr/bin/python3",
            "sentinel_expected_hostname": b["node"], "sentinel_expected_nonce": b["nonce"]}
    return {"all": {"children": {"sentinel_sandbox": {"hosts": hosts, "children": {
        "sentinel_control_plane": {"hosts": {"cp01": {}}},
        "sentinel_workers": {"hosts": {"w01": {}}}}}}}}


def render_playbook(stage: str, source: str) -> str:
    """Render only reviewed network literals; refuse unexpected source changes."""
    if stage in {"init", "cni"}:
        if source.count("10.244.0.0/16") != 1:
            raise Blocked("Unexpected source Pod CIDR occurrences")
        source = source.replace("10.244.0.0/16", POD_CIDR)
    if stage == "init":
        if source.count("10.96.0.0/12") != 1:
            raise Blocked("Unexpected source Service CIDR occurrences")
        source = source.replace("10.96.0.0/12", SERVICE_CIDR)
    if stage == "network-test":
        old_pattern = '^10[.]244[.][0-9]+[.][0-9]+$'
        network = ipaddress.ip_network(POD_CIDR)
        if network.version != 4 or network.prefixlen != 16 or source.count(old_pattern) != 2:
            raise Blocked("Unexpected active-network Pod CIDR assertions")
        prefix = '[.]'.join(str(network.network_address).split('.')[:2])
        source = source.replace(old_pattern, '^' + prefix + '[.][0-9]+[.][0-9]+$')
    return source


def render_flannel(payload: bytes, upstream_sha: str) -> bytes:
    if not re.fullmatch(r"[a-f0-9]{64}", upstream_sha) or hashlib.sha256(payload).hexdigest() != upstream_sha:
        raise Blocked("Upstream Flannel digest mismatch")
    text = payload.decode("utf-8")
    docs = list(yaml.safe_load_all(text))
    maps = [d for d in docs if isinstance(d, dict) and d.get("kind") == "ConfigMap"
            and d.get("metadata", {}).get("name") == "kube-flannel-cfg"]
    if len(maps) != 1 or json.loads(maps[0]["data"]["net-conf.json"]).get("Network") != "10.244.0.0/16":
        raise Blocked("Unexpected upstream Flannel network configuration")
    if text.count("10.244.0.0/16") != 1 or f"ghcr.io/flannel-io/flannel:{FLANNEL_VERSION}" not in text:
        raise Blocked("Unexpected Flannel release layout or version")
    network = json.loads(maps[0]["data"]["net-conf.json"])
    network["Network"] = POD_CIDR
    maps[0]["data"]["net-conf.json"] = json.dumps(network, indent=2) + "\n"
    daemons = [d for d in docs if isinstance(d, dict) and d.get("kind") == "DaemonSet"
               and d.get("metadata", {}).get("name") == "kube-flannel-ds"]
    if len(daemons) != 1:
        raise Blocked("Expected exactly one Flannel DaemonSet")
    containers = [c for c in daemons[0]["spec"]["template"]["spec"]["containers"] if c.get("name") == "kube-flannel"]
    if len(containers) != 1 or containers[0].get("image") != f"ghcr.io/flannel-io/flannel:{FLANNEL_VERSION}":
        raise Blocked("Unexpected Flannel container")
    args = containers[0].get("args", [])
    if not isinstance(args, list) or "--kube-subnet-mgr" not in args or any(a.startswith("--iface") for a in args):
        raise Blocked("Unexpected Flannel interface arguments")
    # Both guests have management + private NICs. Bind VXLAN to the seed's
    # private sentinel0 interface rather than auto-selecting management DHCP.
    containers[0]["args"] = [*args, "--iface=sentinel0"]
    return yaml.safe_dump_all(docs, sort_keys=False).encode("utf-8")


def require_approval(stage: str, approval: str | None) -> None:
    expected = "FRESH_" + stage.upper().replace("-", "_")
    if stage not in STAGES or (stage not in READ_ONLY and approval != expected):
        raise Blocked("Explicit per-stage approval required")
    if stage in READ_ONLY and approval:
        raise Blocked("Read-only stage does not accept approval")


def load_bindings(root: Path) -> list[dict]:
    bindings = []
    for name in NODES:
        folder = root / name
        for path in (folder, folder / "provisioning.json", folder / "trusted_known_hosts"):
            if path.is_symlink() or not path.exists():
                raise Blocked("Missing or symlinked identity/trust state")
        manifest = folder / "provisioning.json"
        trust = folder / "trusted_known_hosts"
        if manifest.stat().st_size > 4096 or trust.stat().st_size > 1024:
            raise Blocked("Oversized identity/trust record")
        bindings.append(validate_binding(name, json.loads(manifest.read_text(encoding="utf-8-sig")),
                                         trust.read_text(encoding="ascii")))
    validate_pair(bindings)
    return bindings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=STAGES, required=True)
    parser.add_argument("--approval")
    parser.add_argument("--key", required=True)
    parser.add_argument("--flannel-sha256")
    args = parser.parse_args()
    require_approval(args.stage, args.approval)
    if os.name != "posix" or not str(Path.home()).startswith("/home/"):
        raise Blocked("Run through the Windows controller in the existing WSL Ubuntu environment")
    if args.stage == "cni" and not re.fullmatch(r"[a-f0-9]{64}", args.flannel_sha256 or ""):
        raise Blocked("CNI needs the independently reviewed upstream v0.28.10 SHA256")
    if not Path(args.key).is_file():
        raise Blocked("Existing WSL login key missing")
    bindings = load_bindings(ROOT)
    state = Path.home() / ".local/state/sentinel-fresh"
    # Reject symlinked state ancestry before mkdir/write.
    for parent in (state, *state.parents):
        if parent.is_symlink():
            raise Blocked("Symlinked controller state ancestry")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    if state.stat().st_mode & 0o077:
        raise Blocked("Fresh controller state permissions too open")
    run = Path(tempfile.mkdtemp(prefix=args.stage + "-", dir=state))
    os.chmod(run, 0o700)
    old_mask = os.umask(0o077)
    try:
        trust = run / "known_hosts"
        trust.write_text("".join(b["trustedLine"] for b in bindings), encoding="ascii")
        inventory = run / "inventory.json"
        inventory.write_text(json.dumps(build_inventory(bindings, args.key, trust)), encoding="utf-8")
        variables = {
            "sentinel_fresh_stage": args.stage,
            "sentinel_apply_approved": args.stage == "baseline",
            "sentinel_containerd_version": "2.2.2-0ubuntu1.2",
            "sentinel_repo_bootstrap_approved": args.stage == "repository",
            "sentinel_report_root": str(run),
            "sentinel_k8s_install_approved": args.stage == "packages",
            "sentinel_k8s_version": "1.37.2-1.1",
            "sentinel_kubeadm_mode": "apply",
            "sentinel_cp_init_approved": args.stage == "init",
            "sentinel_reconcile_mode": "apply" if args.stage in {"cni", "join", "network-test"} else "plan",
            "sentinel_reconcile_approved": args.stage in {"cni", "join", "network-test"},
            "sentinel_network_test_enabled": args.stage == "network-test",
            "sentinel_netcheck_namespace": "sentinel-netcheck-" + secrets.token_hex(6),
            "sentinel_netcheck_image": "busybox:1.37.0",
        }
        hashes = {}
        if args.stage == "cni":
            upstream = run / "flannel-upstream.yml"
            retrieve_verified_release(FLANNEL_VERSION, args.flannel_sha256, upstream)
            rendered = render_flannel(upstream.read_bytes(), args.flannel_sha256)
            artifact = run / "flannel-fresh.yml"
            artifact.write_bytes(rendered)
            digest = hashlib.sha256(rendered).hexdigest()
            hashes = {"upstreamSHA256": args.flannel_sha256, "renderedSHA256": digest}
            variables.update(sentinel_flannel_version=FLANNEL_VERSION,
                             sentinel_flannel_sha256=digest, sentinel_flannel_artifact=str(artifact))
        source = (PLAYBOOKS / STAGES[args.stage]).read_text(encoding="utf-8")
        rendered_playbook = run / "stage.yml"
        rendered_playbook.write_text(render_playbook(args.stage, source), encoding="utf-8")
        variables_path = run / "vars.json"
        variables_path.write_text(json.dumps(variables), encoding="utf-8")
        env = dict(os.environ, ANSIBLE_HOST_KEY_CHECKING="True", ANSIBLE_CONFIG=str(run / "ansible.cfg"))
        (run / "ansible.cfg").write_text("[defaults]\nhost_key_checking=True\nretry_files_enabled=False\n[ssh_connection]\nssh_args=-C -o ControlMaster=no\n", encoding="ascii")
        results = []
        audit = {"profile": "sentinel-fresh-cluster-v1", "stage": args.stage,
                 "vmIds": [b["vmId"] for b in bindings], "imageSHA256": bindings[0]["sourceImageSHA256"],
                 "sourcePlaybookSHA256": hashlib.sha256(source.encode()).hexdigest(), **hashes,
                 "status": "failed", "steps": results}
        try:
            for playbook in (PLAYBOOKS / "05-fresh-identity.yml", PLAYBOOKS / "00-readiness.yml", rendered_playbook):
                # Revalidate local binding files before each stage; never use a completion flag to skip identity.
                if load_bindings(ROOT) != bindings:
                    raise Blocked("Binding changed during stage")
                completed = subprocess.run(["ansible-playbook", "-i", str(inventory),
                    "-e", "@" + str(variables_path), str(playbook)], env=env, check=False)
                results.append({"playbook": playbook.name, "exitCode": completed.returncode})
                if completed.returncode:
                    raise Blocked("Stage failed; inspect private audit, no automatic retry or cleanup")
            audit["status"] = "passed"
        finally:
            (run / "audit.json").write_text(json.dumps(audit, indent=2), encoding="utf-8")
            print("FRESH_AUDIT: " + str(run / "audit.json"), flush=True)
        print("FRESH_STAGE_PASS: " + args.stage, flush=True)
    finally:
        os.umask(old_mask)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, KeyError, yaml.YAMLError) as exc:
        raise SystemExit("BLOCKED: " + str(exc))
