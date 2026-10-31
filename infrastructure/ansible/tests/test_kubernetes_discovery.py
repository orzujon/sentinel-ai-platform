"""Stage 4.3.1 read-only kubeadm discovery, safety and network-analysis tests."""
from pathlib import Path
import copy
import json
import sys
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from run_readiness import (
    BASELINE_CONTAINERD_VERSION, Stage4Blocked,
    check_kubernetes_discovery_report, parse_host_addresses,
    parse_ip_routes, parse_listen_ports, STAGE43_POD_CIDR, STAGE43_SERVICE_CIDR,
)

PLAYBOOK = ROOT / "playbooks" / "40-kubernetes-discovery.yml"


def sample_report():
    addr = [
        {"ifname": "lo", "addr_info": [{"family": "inet", "local": "127.0.0.1"}]},
        {"ifname": "eth1", "addr_info": [{"family": "inet", "local": "10.78.0.10"}]},
    ]
    routes = [
        {"dst": "default", "gateway": "172.20.0.1", "dev": "eth0"},
        {"dst": "10.78.0.0/24", "dev": "eth1"},
        {"dst": "172.20.0.0/20", "dev": "eth0"},
    ]
    return {
        "distribution": "Ubuntu", "distributionVersion": "26.04",
        "architecture": "x86_64", "k8sMarkers": [False] * 5,
        "kubeadmPolicyRaw": "kubeadm:\n  Installed: (none)\n  Candidate: (none)\n",
        "kubeletPolicyRaw": "kubelet:\n  Installed: (none)\n  Candidate: (none)\n",
        "kubectlPolicyRaw": "kubectl:\n  Installed: (none)\n  Candidate: (none)\n",
        "kubeadmInstalled": "not-installed", "kubeletInstalled": "not-installed",
        "kubectlInstalled": "not-installed",
        "containerdInstalled": BASELINE_CONTAINERD_VERSION,
        "containerdService": "active",
        "criPluginsRaw": "io.containerd.cri.v1.runtime  linux/amd64  ok",
        "criSocketExists": True, "ipv4Forwarding": "1",
        "swapEntries": 0, "addressesRaw": json.dumps(addr),
        "routesRaw": json.dumps(routes),
        "tcpListenersRaw": "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*",
        "kubeletService": "inactive",
    }


def check(report):
    return check_kubernetes_discovery_report(
        report, target_ip="10.78.0.10",
        protected_networks=["10.77.0.0/24", "10.78.0.0/24"]
    )


class KubernetesDiscoveryTests(unittest.TestCase):
    def test_read_only_discovery_uses_no_guest_mutation_modules(self):
        plays = yaml.safe_load(PLAYBOOK.read_text(encoding="utf-8"))
        self.assertEqual(len(plays), 1)
        play = plays[0]
        self.assertEqual(play["hosts"], "sentinel_sandbox")
        self.assertNotIn("become", play)
        self.assertTrue(play["any_errors_fatal"])
        accepted = {
            "ansible.builtin.assert", "ansible.builtin.command",
            "ansible.builtin.stat", "ansible.builtin.copy",
            "ansible.builtin.debug",
        }
        for task in play["tasks"]:
            modules = set(task) & accepted
            self.assertEqual(len(modules), 1, task["name"])
            module = modules.pop()
            self.assertFalse(
                any(k.startswith("ansible.builtin.") and k not in accepted for k in task)
            )
            if module == "ansible.builtin.command":
                self.assertIs(task["changed_when"], False)
            if module == "ansible.builtin.copy":
                self.assertEqual(task["delegate_to"], "localhost")
                self.assertIs(task["become"], False)
                self.assertIs(task["no_log"], True)
                self.assertEqual(task[module]["mode"], "0600")

    def test_good_discovery_without_kubernetes_package_repo_is_successful(self):
        r = check(sample_report())
        self.assertEqual(r, {"kubeadm": None, "kubelet": None, "kubectl": None})

    def test_installed_kubernetes_or_initialized_cluster_blocks(self):
        for key in ("kubeadmInstalled", "kubeletInstalled", "kubectlInstalled"):
            r = sample_report()
            r[key] = "1.37.0-1.1"
            with self.subTest(key=key), self.assertRaises(Stage4Blocked):
                check(r)
        r = sample_report()
        r["k8sMarkers"][2] = True
        with self.assertRaises(Stage4Blocked):
            check(r)

    def test_existing_network_overlap_blocks(self):
        for overlap in ("10.244.0.0/24", "10.96.0.0/16"):
            r = sample_report()
            routes = json.loads(r["routesRaw"])
            routes.append({"dst": overlap, "dev": "eth3"})
            r["routesRaw"] = json.dumps(routes)
            with self.subTest(network=overlap), self.assertRaises(Stage4Blocked):
                check(r)

    def test_listening_kubernetes_port_blocks(self):
        r = sample_report()
        r["tcpListenersRaw"] += "\nLISTEN 0 128 [::]:6443 [::]:*"
        with self.assertRaises(Stage4Blocked):
            check(r)

    def test_baseline_mismatch_blocks(self):
        variants = [
            ("containerdInstalled", "2.0.0"),
            ("containerdService", "inactive"),
            ("criSocketExists", False),
            ("criPluginsRaw", ""),
            ("ipv4Forwarding", "0"),
            ("swapEntries", 1),
            ("kubeletService", "active"),
        ]
        for key, value in variants:
            r = sample_report()
            r[key] = value
            with self.subTest(key=key), self.assertRaises(Stage4Blocked):
                check(r)

    def test_wrong_ip_blocks(self):
        r = sample_report()
        r["addressesRaw"] = "[]"
        with self.assertRaises(Stage4Blocked):
            check(r)

    def test_report_must_include_all_fields(self):
        r = sample_report()
        del r["routesRaw"]
        with self.assertRaises(Stage4Blocked):
            check(r)

    def test_package_candidates_parse_from_raw_apt_metadata(self):
        r = sample_report()
        candidate = "1.37.0-1.1"
        for name in ("kubeadm", "kubelet", "kubectl"):
            r[name + "PolicyRaw"] = f"{name}:\n  Candidate: {candidate}\n"
        self.assertEqual(
            check(r), {name: candidate for name in ("kubeadm", "kubelet", "kubectl")}
        )

    def test_cidr_design_and_parsers(self):
        self.assertFalse(STAGE43_POD_CIDR.overlaps(STAGE43_SERVICE_CIDR))
        self.assertEqual(len(parse_ip_routes(sample_report()["routesRaw"])), 2)
        self.assertEqual(len(parse_host_addresses(sample_report()["addressesRaw"])), 2)
        self.assertEqual(parse_listen_ports(sample_report()["tcpListenersRaw"]), {22})


if __name__ == "__main__":
    unittest.main()
