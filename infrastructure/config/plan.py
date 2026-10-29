#!/usr/bin/env python3
"""Sentinel config plan: validate pinned, private YAML WITHOUT touching Hyper-V.

Requires PyYAML. This is NOT the provisioning/apply command. It never fetches
secrets or images, and never resolves secret references.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import re
import subprocess
import sys
from pathlib import PureWindowsPath
from urllib.parse import urlparse

import yaml

from image_catalog import CatalogError, resolve_catalog

API_VERSION = "infra.sentinel.dev/v1alpha1"
# Fixed platform protections, intentionally NOT sourced from editable env YAML.
PROTECTED_VMS = frozenset({"k8s-cp01", "k8s-w01"})
PROTECTED_SWITCHES = frozenset({"Sentinel-K8s", "Default Switch"})
PROTECTED_NETWORKS = (ipaddress.ip_network("10.77.0.0/24"),)
CONFIG_REMOTE_URLS = frozenset({
    "https://github.com/orzujon/sentinel-environment-config.git",
    "git@github.com:orzujon/sentinel-environment-config.git",
    "ssh://git@github.com/orzujon/sentinel-environment-config.git",
})
HEX_SHA = re.compile(r"^[a-fA-F0-9]{40}$")
HEX_DIGEST = re.compile(r"^[a-fA-F0-9]{64}$")
ENV_NAME = re.compile(r"^[a-z][a-z0-9-]{0,39}$")
VM_NAME = re.compile(r"^sentinel-[a-z0-9-]{1,52}$")
MAX_YAML_BYTES = 65536


class ConfigError(ValueError):
    """Safe-to-display configuration validation failure."""


class StrictLoader(yaml.SafeLoader):
    """Safe YAML decoder that fails on duplicate mapping keys."""


def _mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=True)
        if not isinstance(key, str) or key in result:
            raise ConfigError("YAML keys must be unique strings")
        result[key] = loader.construct_object(value_node, deep=True)
    return result


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


def require_keys(obj, required, optional=(), label="section"):
    if not isinstance(obj, dict):
        raise ConfigError(f"{label} must be a mapping")
    absent = set(required) - obj.keys()
    extra = obj.keys() - set(required) - set(optional)
    if absent or extra:
        raise ConfigError(f"{label} has missing or unsupported fields")
    return obj


def text_value(value, label, pattern=None):
    if not isinstance(value, str) or not value or (pattern and not pattern.fullmatch(value)):
        raise ConfigError(f"{label} must be a valid string")
    return value


def sized_int(value, minimum, maximum, label):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ConfigError(f"{label} is outside approved limits")
    return value


def parse_yaml(source):
    if len(source.encode("utf-8")) > MAX_YAML_BYTES:
        raise ConfigError("Configuration is larger than the permitted limit")
    try:
        obj = yaml.load(source, Loader=StrictLoader)
    except yaml.YAMLError as exc:
        raise ConfigError("Invalid YAML document") from exc
    return obj


def read_pinned_config(repo, revision, environment):
    """Read-only: git show <immutable SHA>:<allowlisted path>; no checkout/pull."""
    text_value(environment, "environment", ENV_NAME)
    text_value(revision, "revision", HEX_SHA)

    def git(*args):
        proc = subprocess.run(
            ["git", "-C", str(repo), *args],
            capture_output=True, text=True, encoding="utf-8", timeout=12, check=False,
        )
        if proc.returncode:
            raise ConfigError("Cannot read the approved local config clone/revision")
        return proc.stdout.strip()

    origin = git("remote", "get-url", "origin")
    if origin not in CONFIG_REMOTE_URLS:
        raise ConfigError("Configuration clone origin is not the approved private repository")
    actual = git("rev-parse", "--verify", revision + "^{commit}")
    if actual.lower() != revision.lower():
        raise ConfigError("Configuration revision must identify an immutable commit")
    return git("show", f"{revision}:environments/{environment}.yaml")


def validate(doc, environment=None):
    require_keys(doc, ("apiVersion", "kind", "metadata", "spec"), label="document")
    if doc["apiVersion"] != API_VERSION or doc["kind"] != "SentinelEnvironment":
        raise ConfigError("Unsupported Sentinel environment version/kind")
    meta = require_keys(doc["metadata"], ("name",), label="metadata")
    name = text_value(meta["name"], "environment name", ENV_NAME)
    if environment is not None and name != environment:
        raise ConfigError("Environment path and YAML metadata do not match")

    s = require_keys(doc["spec"], ("provider", "mode", "provisioningEnabled", "host",
                                    "image", "network", "vms", "capacity", "protection",
                                    "identity", "secretRefs"), label="spec")
    if s["provider"] != "hyperv" or s["mode"] != "isolated-sandbox":
        raise ConfigError("Unsupported provider or mode")
    if type(s["provisioningEnabled"]) is not bool:
        raise ConfigError("provisioningEnabled must be a boolean")

    host = require_keys(s["host"], ("vmRoot", "imageCache", "wslDistribution"), label="host")
    root = text_value(host["vmRoot"], "VM storage root")
    wp = PureWindowsPath(root)
    parts = wp.parts
    if (len(parts) != 4 or parts[0].lower() != "c:\\"
            or parts[1].lower() != "sentinel"
            or not re.fullmatch(r"Level1-[A-Za-z0-9-]+", parts[2])
            or parts[3].lower() != "vms" or ".." in parts):
        raise ConfigError("VM storage root is outside the protected Level1 sandbox")
    if host["imageCache"] != "C:\\Sentinel\\ImageCache":
        raise ConfigError("Unapproved image cache directory")
    if host["wslDistribution"] != "Ubuntu-26.04":
        raise ConfigError("Unapproved WSL tooling distribution")

    img = require_keys(s["image"], ("distribution", "architecture", "buildId",
                                     "sourceUrl", "expectedSha256"), optional=("imageRef",), label="image")
    if img["distribution"] != "Ubuntu" or img["architecture"] != "amd64":
        raise ConfigError("Unsupported source image")
    if not re.fullmatch(r"20[0-9]{6}", str(img["buildId"])):
        raise ConfigError("Image build must be a pinned eight-digit date")
    parsed = urlparse(text_value(img["sourceUrl"], "image source URL"))
    expected_path = (f"/releases/26.04/release-{img['buildId']}/"
                     "ubuntu-26.04-server-cloudimg-amd64.img")
    if (parsed.scheme != "https" or parsed.netloc != "cloud-images.ubuntu.com"
            or parsed.path != expected_path or parsed.query or parsed.fragment):
        raise ConfigError("Image source must be the approved Canonical HTTPS release path")
    if "imageRef" in img:
        if not isinstance(img["imageRef"], str) or not re.fullmatch(r"^[a-z][a-z0-9.-]{1,79}$", img["imageRef"]):
            raise ConfigError("Invalid imageRef")
    digest = img["expectedSha256"]
    if digest is not None and (not isinstance(digest, str) or not HEX_DIGEST.fullmatch(digest)):
        raise ConfigError("Image SHA256 must be null or 64 hexadecimal characters")

    net = require_keys(s["network"], ("managementSwitch", "privateSwitch", "type",
                                      "subnet", "hostIP"), label="network")
    if net["managementSwitch"] != "Default Switch" or net["type"] != "Internal":
        raise ConfigError("Unsupported management switch or private switch type")
    switch = text_value(net["privateSwitch"], "private switch")
    if switch in PROTECTED_SWITCHES or not re.fullmatch(r"Sentinel-[A-Za-z0-9-]{1,40}", switch):
        raise ConfigError("Private switch is protected or outside namespace")
    try:
        subnet = ipaddress.ip_network(net["subnet"], strict=True)
        host_ip = ipaddress.ip_address(net["hostIP"])
    except (ValueError, TypeError, KeyError) as exc:
        raise ConfigError("Invalid private IPv4 network") from exc
    if subnet.version != 4 or host_ip not in subnet or host_ip in (subnet.network_address, subnet.broadcast_address):
        raise ConfigError("Private IPv4 host address is outside valid subnet hosts")
    if any(subnet.overlaps(protected) for protected in PROTECTED_NETWORKS):
        raise ConfigError("Private subnet overlaps a protected lab network")

    vms = s["vms"]
    if not isinstance(vms, list) or not 1 <= len(vms) <= 8:
        raise ConfigError("Environment must contain 1 to 8 VMs")
    names, ips = set(), {str(host_ip)}
    for vm in vms:
        require_keys(vm, ("name", "role", "staticIP", "virtualProcessors",
                          "memoryGB", "diskGB"), label="VM")
        vm_name = text_value(vm["name"], "VM name", VM_NAME)
        if vm_name in PROTECTED_VMS or vm_name in names:
            raise ConfigError("VM name is protected or duplicated")
        names.add(vm_name)
        if vm["role"] not in ("control-plane", "worker"):
            raise ConfigError("Unsupported VM role")
        sized_int(vm["virtualProcessors"], 1, 16, "virtual processors")
        sized_int(vm["memoryGB"], 2, 32, "fixed memory")
        sized_int(vm["diskGB"], 30, 512, "disk capacity")
        try:
            ip = ipaddress.ip_address(vm["staticIP"])
        except (ValueError, TypeError) as exc:
            raise ConfigError("Invalid VM static IP") from exc
        if ip not in subnet or ip in (subnet.network_address, subnet.broadcast_address) or str(ip) in ips:
            raise ConfigError("VM address is duplicated or outside private subnet")
        ips.add(str(ip))

    cap = require_keys(s["capacity"], ("hostRAMReserveGB", "hostLogicalCPUReserve",
                                      "diskReserveGB"), label="capacity")
    sized_int(cap["hostRAMReserveGB"], 2, 128, "host RAM reserve")
    sized_int(cap["hostLogicalCPUReserve"], 1, 64, "host CPU reserve")
    sized_int(cap["diskReserveGB"], 10, 1000, "host disk reserve")

    protection = require_keys(s["protection"], ("vmNames", "switchNames", "subnets"), label="protection")
    for k in ("vmNames", "switchNames", "subnets"):
        if not isinstance(protection[k], list) or not all(isinstance(x, str) for x in protection[k]):
            raise ConfigError("Protection entries must be lists of strings")
    if not PROTECTED_VMS.issubset(set(protection["vmNames"])):
        raise ConfigError("Protected baseline VMs cannot be removed")
    if not PROTECTED_SWITCHES.issubset(set(protection["switchNames"])):
        raise ConfigError("Protected baseline switches cannot be removed")
    if not {"10.77.0.0/24"}.issubset(set(protection["subnets"])):
        raise ConfigError("Protected baseline subnets cannot be removed")
    if any(vm["name"] in protection["vmNames"] for vm in vms) or switch in protection["switchNames"]:
        raise ConfigError("Requested targets conflict with environment protections")
    try:
        if any(subnet.overlaps(ipaddress.ip_network(x, strict=True)) for x in protection["subnets"]):
            raise ConfigError("Private subnet overlaps environment protections")
    except ValueError as exc:
        raise ConfigError("Malformed protected subnet") from exc

    ident = require_keys(s["identity"], ("username", "sshPublicKeyRef"), label="identity")
    if ident["username"] != "orzu" or ident["sshPublicKeyRef"] != "local-user-ed25519-pub":
        raise ConfigError("Unsupported lab SSH identity reference")
    refs = s["secretRefs"]
    if not isinstance(refs, dict) or any(not isinstance(k, str) or
            not isinstance(v, str) or not re.fullmatch(r"vault://[A-Za-z0-9/_-]+", v)
            for k, v in refs.items()):
        raise ConfigError("Only opaque vault:// secret references are supported")
    # Never resolve refs, and never include them in a plan.
    return name, s


def build_plan(doc, revision, environment=None, catalog_data=None, catalog_sha256=None):
    name, spec = validate(doc, environment)
    summary = {
        "schemaVersion": "1.0",
        "environment": name,
        "configRevision": revision,
        "mode": "READ_ONLY_PLAN",
        "status": "PLAN_ONLY",
        "mutations": 0,
        "deploymentPermitted": False,
        "imageApproval": "NOT_IMPLEMENTED",
        "imageDigestPinned": spec["image"]["expectedSha256"] is not None,
        "provisioningEnabledInConfig": spec["provisioningEnabled"],
        "vmCount": len(spec["vms"]),
        "vmNames": [vm["name"] for vm in spec["vms"]],
        "totalRequestedMemoryGB": sum(vm["memoryGB"] for vm in spec["vms"]),
        "totalRequestedCPUs": sum(vm["virtualProcessors"] for vm in spec["vms"]),
        "privateSubnet": spec["network"]["subnet"],
        "notes": ["No Hyper-V calls or remote secret resolution.",
                  "Host capacity, artifact signatures, image catalog and deployment approval are not checked.",
                  "Current sentinel.ps1 still consumes local lab.json; this plan cannot be applied."],
    }
    if catalog_data is not None:
        try:
            summary["imageCatalog"] = resolve_catalog(
                catalog_data, catalog_sha256, spec["image"]
            )
        except CatalogError as exc:
            raise ConfigError(str(exc)) from exc
    # Include the independently pinned image catalog in the plan fingerprint.
    # This is only an identification digest, never a deployment approval token.
    summary["planSha256"] = hashlib.sha256(
        json.dumps({"configuration": doc, "revision": revision,
                    "catalogPin": catalog_sha256 if catalog_data is not None else None,
                    "resolvedImage": (summary["imageCatalog"]["imageSha256"]
                                      if catalog_data is not None else None)},
                   sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description="Non-mutating Sentinel private YAML configuration plan")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--config-file", help="Local YAML file for offline testing (not a deployment source)")
    source.add_argument("--config-repo", help="Locally authenticated, private config Git clone")
    parser.add_argument("--revision", help="Full 40-character pinned commit SHA, required with --config-repo")
    parser.add_argument("--environment", required=True, help="Environment name, e.g. lab")
    parser.add_argument("--catalog-file", help="Approved catalog file (offline and read-only)")
    parser.add_argument("--catalog-sha256", help="64-hex catalog digest pinned outside private env config")
    args = parser.parse_args(argv)
    try:
        if not ENV_NAME.fullmatch(args.environment):
            raise ConfigError("Invalid environment name")
        if args.config_repo:
            if not args.revision:
                raise ConfigError("A pinned 40-character revision is required")
            raw = read_pinned_config(args.config_repo, args.revision, args.environment)
            revision = args.revision.lower()
        else:
            if args.revision:
                raise ConfigError("--revision only applies to --config-repo")
            from pathlib import Path
            raw = Path(args.config_file).read_text(encoding="utf-8")
            revision = "LOCAL_TEST_ONLY"
        if bool(args.catalog_file) != bool(args.catalog_sha256):
            raise ConfigError("Specify --catalog-file and --catalog-sha256 together")
        catalog = None
        if args.catalog_file:
            from pathlib import Path
            catalog = Path(args.catalog_file).read_bytes()
        result = build_plan(parse_yaml(raw), revision, args.environment,
                            catalog_data=catalog, catalog_sha256=args.catalog_sha256)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (ConfigError, OSError, subprocess.TimeoutExpired) as exc:
        # Do not print raw YAML, path contents, Git stderr or secret references.
        print(json.dumps({"status": "BLOCKED", "mutations": 0,
                          "reason": str(exc) if isinstance(exc, ConfigError)
                          else "Cannot access the configuration source"}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
