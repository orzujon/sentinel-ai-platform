#!/usr/bin/env python3
"""Sentinel Guardian Level 1: one deterministic, opt-in healing experiment.

This is NOT an LLM executor. The only supported mutation is scaling the exact
synthetic demo deployment from zero to one replica after fresh-cluster identity
checks, an immutable plan match, namespace/deployment UID pins, and an explicit
operator approval. Default mode is read-only; no loops or retries.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

NAMESPACE = "sentinel-healing-lab"
DEPLOYMENT = "sentinel-demo-api"
NODES = {"cp01", "w01"}
MARKER = "sentinel.ai/demo-only"
APPROVAL = "HEAL_EXACT_SENTINEL_DEMO"
UID = re.compile(r"^[a-f0-9-]{36}$", re.I)
SHA = re.compile(r"^[0-9a-f]{64}$")


class Blocked(RuntimeError):
    pass


def canonical(obj: dict) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def name_and_metadata(obj: dict, name: str, *, demo: bool) -> tuple[str, str]:
    if not isinstance(obj, dict):
        raise Blocked("Expected Kubernetes object missing")
    meta = obj.get("metadata")
    if not isinstance(meta, dict) or meta.get("name") != name:
        raise Blocked("Unexpected Kubernetes object identity")
    uid, rv = meta.get("uid"), meta.get("resourceVersion")
    if not isinstance(uid, str) or not UID.fullmatch(uid) or not isinstance(rv, str) or not rv.isdecimal():
        raise Blocked("Missing exact UID or resource version")
    if meta.get("deletionTimestamp") is not None:
        raise Blocked("Refusing a terminating object")
    if demo and (not isinstance(meta.get("labels"), dict)
                 or meta["labels"].get(MARKER) != "true"):
        raise Blocked("Demo-only scope marker missing")
    return uid, rv


def ready_nodes(payload: dict) -> list[str]:
    if not isinstance(payload, dict) or not isinstance(payload.get("items"), list):
        raise Blocked("Missing Kubernetes node inventory")
    result = {}
    for node in payload["items"]:
        if not isinstance(node, dict) or not isinstance(node.get("metadata"), dict):
            raise Blocked("Malformed node inventory")
        name = node["metadata"].get("name")
        if not isinstance(name, str) or name in result:
            raise Blocked("Duplicate or malformed node")
        ready = any(c.get("type") == "Ready" and c.get("status") == "True"
                    for c in node.get("status", {}).get("conditions", [])
                    if isinstance(c, dict))
        result[name] = ready
    if set(result) != NODES or not all(result.values()):
        raise Blocked("Not the exact two-node Ready fresh-cluster target")
    return sorted(result)


def create_plan(snapshot: dict) -> dict:
    if not isinstance(snapshot, dict) or set(snapshot) != {"nodes", "namespace", "deployment"}:
        raise Blocked("Snapshot must contain only nodes, namespace and deployment")
    nodes = ready_nodes(snapshot["nodes"])
    ns_uid, _ = name_and_metadata(snapshot["namespace"], NAMESPACE, demo=True)
    deploy = snapshot["deployment"]
    dep_uid, rv = name_and_metadata(deploy, DEPLOYMENT, demo=True)
    if deploy.get("metadata", {}).get("namespace") != NAMESPACE:
        raise Blocked("Deployment not in the exact synthetic namespace")
    if deploy.get("metadata", {}).get("annotations", {}).get("sentinel.ai/desired-replicas") != "1":
        raise Blocked("Required fixed recovery intention not declared")
    selector = deploy.get("spec", {}).get("selector", {}).get("matchLabels", {})
    pod_labels = deploy.get("spec", {}).get("template", {}).get("metadata", {}).get("labels", {})
    if not isinstance(selector, dict) or not isinstance(pod_labels, dict) or not selector:
        raise Blocked("Missing deployment pod selector")
    if selector.get("app") != DEPLOYMENT or pod_labels.get("app") != DEPLOYMENT:
        raise Blocked("Demo selector mismatch")
    replicas = deploy.get("spec", {}).get("replicas")
    available = deploy.get("status", {}).get("availableReplicas", 0)
    if type(replicas) is not int or type(available) is not int or replicas < 0 or available < 0:
        raise Blocked("Untrusted deployment replica counts")
    # A zero replica count normally represents an intentional desired state.
    # Only an exact, labelled lab deployment with an independently declared
    # recovery goal is permitted for this experiment.
    if replicas == 0 and available == 0:
        decision, reason = "PROPOSE_SCALE_TO_ONE", "demo_zero_replicas_with_pinned_recovery_goal"
    elif replicas == 1 and available == 1:
        decision, reason = "HEALTHY", "one_desired_and_one_available"
    else:
        decision, reason = "ABSTAIN", "state_not_supported_by_safe_recovery_policy"
    plan = {
        "schemaVersion": "sentinel-guardian-l1/v1",
        "scope": "synthetic-demo-only",
        "clusterNodes": nodes,
        "namespace": NAMESPACE,
        "namespaceUID": ns_uid,
        "deployment": DEPLOYMENT,
        "deploymentUID": dep_uid,
        "deploymentResourceVersion": rv,
        "observedReplicas": replicas,
        "availableReplicas": available,
        "fixedDesiredReplicas": 1,
        "decision": decision,
        "reason": reason,
        "humanApprovalRequired": True,
    }
    plan["planSHA256"] = hashlib.sha256(canonical(plan).encode("ascii")).hexdigest()
    return plan


def fetch_snapshot(context: str) -> dict:
    if not isinstance(context, str) or not re.fullmatch(r"[a-zA-Z0-9._:@/-]{1,120}", context):
        raise Blocked("Explicit, simple kubeconfig context required")
    def get(*args: str) -> dict:
        command = ["kubectl", "--context", context, *args, "-o", "json"]
        try:
            proc = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Blocked("Cannot inspect Kubernetes target: " + type(exc).__name__) from exc
        if proc.returncode:
            raise Blocked("Read-only Kubernetes inspection failed; check context and access")
        if len(proc.stdout) > 300_000:
            raise Blocked("Oversized Kubernetes inventory")
        try:
            data = json.loads(proc.stdout)
        except ValueError as exc:
            raise Blocked("Invalid Kubernetes API JSON") from exc
        if not isinstance(data, dict):
            raise Blocked("Unexpected Kubernetes API object")
        return data
    return {
        "nodes": get("get", "nodes"),
        "namespace": get("get", "namespace", NAMESPACE),
        "deployment": get("-n", NAMESPACE, "get", "deployment", DEPLOYMENT),
    }


def scale_exact_demo(*, context: str, plan: dict) -> None:
    if plan.get("decision") != "PROPOSE_SCALE_TO_ONE" or plan.get("observedReplicas") != 0:
        raise Blocked("Only exact zero-to-one synthetic recovery may execute")
    command = ["kubectl", "--context", context, "-n", NAMESPACE,
               "scale", "deployment/" + DEPLOYMENT, "--replicas=1",
               "--current-replicas=0",
               "--resource-version=" + plan["deploymentResourceVersion"]]
    try:
        proc = subprocess.run(command, capture_output=True, text=True, timeout=25, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Blocked("Kubernetes scale failed or timed out; inspect before retrying") from exc
    if proc.returncode:
        raise Blocked("Kubernetes rejected exact guarded scale; no retry attempted")


def execute(args) -> int:
    if args.mode == "apply":
        if args.snapshot or args.approval != APPROVAL or not args.context:
            raise Blocked("Apply requires live context, exact approval and no synthetic input")
        if not args.expected_plan or not SHA.fullmatch(args.expected_plan):
            raise Blocked("Apply needs the precise prior PLAN SHA256")
        if (not args.expected_namespace_uid or not UID.fullmatch(args.expected_namespace_uid)
                or not args.expected_deployment_uid or not UID.fullmatch(args.expected_deployment_uid)):
            raise Blocked("Apply needs both exact observed target UIDs")
    else:
        if args.approval or args.expected_plan or args.expected_namespace_uid or args.expected_deployment_uid:
            raise Blocked("PLAN is read-only and cannot accept mutation arguments")
    if args.snapshot:
        if args.mode != "plan" or args.context:
            raise Blocked("Offline snapshot can only be used for read-only PLAN")
        path = Path(args.snapshot)
        if not path.is_file() or path.is_symlink() or path.stat().st_size > 300_000:
            raise Blocked("Offline snapshot missing, symlinked or oversized")
        snapshot = json.loads(path.read_text(encoding="utf-8"))
    elif args.context:
        snapshot = fetch_snapshot(args.context)
    else:
        raise Blocked("Select an explicit Kubernetes context or offline fixture")
    plan = create_plan(snapshot)
    print(canonical(plan), flush=True)
    if args.mode == "plan":
        print("SENTINEL_GUARDIAN_PLAN: " + plan["decision"], flush=True)
        print("SENTINEL_GUARDIAN_MUTATIONS: 0", flush=True)
        return 0
    if (plan["planSHA256"] != args.expected_plan
            or plan["namespaceUID"].lower() != args.expected_namespace_uid.lower()
            or plan["deploymentUID"].lower() != args.expected_deployment_uid.lower()):
        raise Blocked("Live plan or Kubernetes UID changed; do not replay old approval")
    scale_exact_demo(context=args.context, plan=plan)
    # Verify postcondition through a new live read; workload readiness may lag.
    after = create_plan(fetch_snapshot(args.context))
    if (after["namespaceUID"] != plan["namespaceUID"]
            or after["deploymentUID"] != plan["deploymentUID"]
            or after["observedReplicas"] != 1):
        raise Blocked("Scale submitted but postcondition not established; investigate manually")
    print("SENTINEL_GUARDIAN_ACTION_ACCEPTED: exact demo scaled 0 -> 1; readiness pending independent observation")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["plan", "apply"], default="plan")
    parser.add_argument("--context")
    parser.add_argument("--snapshot", help="Offline-only fixture path")
    parser.add_argument("--approval")
    parser.add_argument("--expected-plan")
    parser.add_argument("--expected-namespace-uid")
    parser.add_argument("--expected-deployment-uid")
    args = parser.parse_args()
    try:
        return execute(args)
    except (Blocked, OSError, ValueError, KeyError, TypeError) as exc:
        print("BLOCKED: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
