"""Stage 4.2 containerd baseline: strict preflight, opt-in mutation, and configuration tests."""
from pathlib import Path
import tomllib
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "playbooks" / "20-containerd-baseline.yml"
RUNNER = ROOT / "run_readiness.py"
WRAPPER = ROOT / "Invoke-SentinelReadiness.ps1"
PIN = "2.2.2-0ubuntu1.2"
APPROVAL = "APPLY_SENTINEL_STAGE42_TO_SANDBOX"


class BaselineApplySafety(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plays = yaml.safe_load(BASELINE.read_text(encoding="utf-8"))
        cls.preflight, cls.apply = cls.plays
        cls.runner = RUNNER.read_text(encoding="utf-8")
        cls.wrapper = WRAPPER.read_text(encoding="utf-8")

    def test_preflight_is_separate_and_runs_before_any_changes(self):
        self.assertEqual(len(self.plays), 2)
        self.assertEqual(self.preflight["hosts"], "sentinel_sandbox")
        self.assertTrue(self.preflight["any_errors_fatal"])
        self.assertNotIn("serial", self.preflight)
        self.assertTrue(self.apply["any_errors_fatal"])
        self.assertEqual(self.apply["serial"], 1)
        self.assertEqual(self.apply["hosts"], "sentinel_sandbox")
        self.assertTrue(self.apply["become"])

    def test_preflight_rejects_existing_cluster_and_unmanaged_runtime(self):
        preflight_text = yaml.safe_dump(self.preflight)
        for value in (
            "/etc/kubernetes/admin.conf",
            "/var/lib/kubelet/config.yaml",
            "/etc/kubernetes/kubelet.conf",
            "/etc/containerd/config.toml",
            "sentinel_apply_approved",
            "sentinel_containerd_version",
            "sentinel_expected_containerd",
            "Candidate:",
            "swap",
        ):
            self.assertIn(value, preflight_text)
        allowed = {
            "ansible.builtin.assert",
            "ansible.builtin.command",
            "ansible.builtin.stat",
            "ansible.builtin.slurp",
        }
        for task in self.preflight["tasks"]:
            self.assertTrue(
                set(task).intersection(allowed),
                f"Unexpected module in preflight task: {task['name']}"
            )

    def test_install_version_is_exact_and_no_auto_upgrade(self):
        tasks = self.apply["tasks"]
        install = next(t["ansible.builtin.apt"] for t in tasks if "ansible.builtin.apt" in t)
        self.assertEqual(install["name"], "containerd={{ sentinel_expected_containerd }}")
        self.assertEqual(install["state"], "present")
        for forbidden in ("update_cache", "allow_downgrade", "allow_change_held_packages", "auto_install_module_deps"):
            self.assertIs(install[forbidden], False)
        self.assertIs(install["fail_on_autoremove"], True)
        self.assertEqual(self.apply["vars"]["sentinel_expected_containerd"], PIN)
        self.assertIn(PIN, self.runner)

    def test_containerd_v2_toml_has_cri_and_systemd_cgroups(self):
        copy = next(t["ansible.builtin.copy"] for t in self.apply["tasks"]
                    if t.get("ansible.builtin.copy", {}).get("dest") == "/etc/containerd/config.toml")
        config = tomllib.loads(copy["content"])
        self.assertEqual(config["version"], 3)
        self.assertEqual(config["disabled_plugins"], [])
        plugin = config["plugins"]["io.containerd.cri.v1.runtime"]["containerd"]
        self.assertEqual(plugin["default_runtime_name"], "runc")
        self.assertEqual(plugin["runtimes"]["runc"]["runtime_type"], "io.containerd.runc.v2")
        self.assertTrue(plugin["runtimes"]["runc"]["options"]["SystemdCgroup"])
        self.assertIn("# Managed by Sentinel", copy["content"])

    def test_sysctl_and_modules_are_managed_and_conditionally_applied(self):
        play_text = BASELINE.read_text(encoding="utf-8")
        self.assertIn("br_netfilter", play_text)
        self.assertIn("overlay", play_text)
        self.assertIn("net.ipv4.ip_forward=1", play_text)
        self.assertIn("net.bridge.bridge-nf-call-iptables=1", play_text)
        self.assertIn("when: sentinel_ip_forward.stdout", play_text)
        self.assertIn("when: sentinel_bridge_forward.stdout", play_text)
        self.assertIn("meta: flush_handlers", play_text)

    def test_apply_cannot_be_implicitly_enabled(self):
        self.assertIn("args.apply_baseline", self.runner)
        self.assertIn("args.approval_token != APPLY_APPROVAL", self.runner)
        self.assertIn("checked_command(", self.runner)
        self.assertIn("if args.plan_baseline or args.apply_baseline:", self.runner)
        self.assertIn(APPROVAL, self.runner)
        self.assertIn(APPROVAL, self.wrapper)
        self.assertIn("[switch]$PlanBaseline", self.wrapper)
        self.assertIn("[switch]$ApplyBaseline", self.wrapper)
        self.assertIn("$ApplyBaseline.IsPresent", self.wrapper)


if __name__ == "__main__":
    unittest.main()
