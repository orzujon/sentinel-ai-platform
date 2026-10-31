#!/usr/bin/env python3
"""Level 1 desired-state Flannel reconciler.

One approved run fetches, pins, verifies, deploys, and observes the exact same
artifact. No copy/paste SHA workflow, no silent unmanaged adoption or upgrade.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request

import yaml


class ReconcileError(Exception):
    pass


def load_desired(path: Path, environment: str) -> dict:
    if not path.is_file() or path.is_symlink():
        raise ReconcileError("Missing trusted desired-state document")
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("schemaVersion") != 1 or data.get("environment") != environment:
        raise ReconcileError("Desired state schema/environment mismatch")
    k8s = data.get("kubernetes")
    if not isinstance(k8s, dict) or k8s.get("version") != "v1.37.2":
        raise ReconcileError("Unsupported Kubernetes desired version; upgrade workflow not implemented")
    if k8s.get("podCIDR") != "10.244.0.0/16" or k8s.get("serviceCIDR") != "10.96.0.0/12":
        raise ReconcileError("Changing cluster CIDRs requires a separate reviewed migration")
    flannel = k8s.get("flannel")
    if not isinstance(flannel, dict):
        raise ReconcileError("Missing Flannel desired release")
    version = flannel.get("version")
    digest = flannel.get("manifestSHA256")
    if not isinstance(version, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        raise ReconcileError("Flannel version must be an exact release tag")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ReconcileError("Flannel release requires a reviewed SHA256 in desired state")
    return {"version": version, "digest": digest}


def retrieve_verified_release(version: str, digest: str, destination: Path) -> None:
    url = f"https://github.com/flannel-io/flannel/releases/download/{version}/kube-flannel.yml"
    request = urllib.request.Request(url, headers={"User-Agent": "Sentinel-Level1/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            payload = response.read(250_001)
    except Exception as exc:
        raise ReconcileError(f"Cannot fetch pinned Flannel artifact over HTTPS: {type(exc).__name__}") from exc
    if not 1_000 < len(payload) <= 250_000:
        raise ReconcileError("Unexpected Flannel release artifact size")
    if hashlib.sha256(payload).hexdigest() != digest:
        raise ReconcileError("Flannel artifact checksum differs from reviewed desired-state lock")
    try:
        manifest = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ReconcileError("Release manifest is not valid UTF-8") from exc
    if "10.244.0.0/16" not in manifest or f"ghcr.io/flannel-io/flannel:{version}" not in manifest:
        raise ReconcileError("Release artifact content does not match expected CNI and Pod CIDR")
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write(payload)


def reconcile(*, inventory: Path, environment: str, mode: str, approval: bool,
              state_root: Path, desired_file: Path | None = None) -> Path:
    if mode not in {"plan", "apply"}:
        raise ReconcileError("Invalid reconciliation mode")
    if mode == "apply" and not approval:
        raise ReconcileError("Explicit environment-scoped deployment approval missing")
    source = desired_file or (Path(__file__).resolve().parent / "desired-state" / f"{environment}.yml")
    release = load_desired(source, environment)
    state_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state_root, 0o700)
    with tempfile.TemporaryDirectory(prefix="reconcile-", dir=state_root) as temp:
        root = Path(temp)
        os.chmod(root, 0o700)
        asset = root / "kube-flannel.yml"
        retrieve_verified_release(release["version"], release["digest"], asset)
        playbooks = [
            ("flannel", Path(__file__).resolve().parent / "playbooks" / "120-reconcile-flannel.yml"),
            ("worker", Path(__file__).resolve().parent / "playbooks" / "130-reconcile-worker.yml"),
        ]
        variables = {
            "sentinel_reconcile_mode": mode,
            "sentinel_reconcile_approved": approval,
            "sentinel_flannel_version": release["version"],
            "sentinel_flannel_sha256": release["digest"],
            "sentinel_flannel_artifact": str(asset),
        }
        print(f"RECONCILE_TARGET: env={environment} flannel={release['version']} artifact_sha256={release['digest']} mode={mode}", flush=True)
        results = []
        for stage, playbook in playbooks:
            command = ["ansible-playbook", "-i", str(inventory),
                       "-e", json.dumps(variables), str(playbook)]
            print(f"RECONCILE_STAGE: {stage} mode={mode}", flush=True)
            completed = subprocess.run(command, check=False)
            results.append({"stage": stage, "exitCode": completed.returncode})
            if completed.returncode:
                break
        success = len(results) == len(playbooks) and all(item["exitCode"] == 0 for item in results)
        # Keep a private audit of all executed stages, including failure.
        audit = state_root / ("reconcile-" + next(tempfile._get_candidate_names()) + ".json")
        fd = os.open(audit, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump({"environment": environment, "mode": mode, "release": release,
                       "status": "success" if success else "failed",
                       "stages": results, "exitCode": results[-1]["exitCode"]}, output, indent=2)
        if not success:
            raise ReconcileError(f"Level 1 reconciliation stage {results[-1]['stage']} failed ({results[-1]['exitCode']}); audit={audit}")
        print(f"RECONCILE_SUCCESS: audit={audit}", flush=True)
        return audit


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--mode", choices=["plan", "apply"], required=True)
    parser.add_argument("--approved", action="store_true")
    args = parser.parse_args()
    try:
        reconcile(inventory=Path(args.inventory), environment=args.environment,
                  mode=args.mode, approval=args.approved,
                  state_root=Path.home() / ".local" / "state" / "sentinel")
    except (OSError, ReconcileError, yaml.YAMLError) as exc:
        parser.exit(2, f"BLOCKED: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
