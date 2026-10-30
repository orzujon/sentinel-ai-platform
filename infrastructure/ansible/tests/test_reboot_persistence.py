"""Stage 4.2 optional reboot validation: safety contract tests.

The reboot operation is destructive to guest uptime; it must never be part
of discovery, baseline plan or installation without separate approval.
"""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
PLAYBOOK = ROOT / "playbooks" / "30-reboot-persistence.yml"
WRAPPER = ROOT / "Invoke-SentinelReadiness.ps1"
RUNNER = ROOT / "run_readiness.py"
APPROVAL = "REBOOT_SENTINEL_STAGE42_SANDBOX"


class RebootPersistenceSafety(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plays = yaml.safe_load(PLAYBOOK.read_text(encoding="utf-8"))
        cls.preflight, cls.reboot = cls.plays
        cls.runner = RUNNER.read_text(encoding="utf-8")
        cls.wrapper = WRAPPER.read_text(encoding="utf-8")

    def test_all_guest_preflight_before_sequential_reboot(self):
        self.assertEqual(len(self.plays), 2)
        self.assertEqual(self.preflight["hosts"], "sentinel_sandbox")
        self.assertTrue(self.preflight["any_errors_fatal"])
        self.assertNotIn("serial", self.preflight)
        self.assertEqual(self.reboot["hosts"], "sentinel_sandbox")
        self.assertEqual(self.reboot["serial"], 1)
        self.assertTrue(self.reboot["any_errors_fatal"])
        self.assertTrue(self.reboot["become"])

    def test_preflight_does_not_mutate_any_guest(self):
        allowed = {"ansible.builtin.assert", "ansible.builtin.stat",
                   "ansible.builtin.command", "ansible.builtin.slurp"}
        for task in self.preflight["tasks"]:
            modules = set(task).intersection(allowed)
            self.assertEqual(len(modules), 1, task["name"])
            module = modules.pop()
            if module == "ansible.builtin.command":
                self.assertIs(task["changed_when"], False)

    def test_reboot_requires_separate_approval_and_installed_runtime(self):
        c = PLAYBOOK.read_text(encoding="utf-8")
        for text in ("sentinel_reboot_approved", "sentinel_reboot_version",
                     "sentinel_expected_hostname", "sentinel_expected_containerd",
                     "/etc/kubernetes/admin.conf", "/var/lib/kubelet/config.yaml",
                     "# Managed by Sentinel Stage 4.2", "SystemdCgroup = true"):
            self.assertIn(text, c)
        self.assertIn(APPROVAL, self.runner)
        self.assertIn(APPROVAL, self.wrapper)
        self.assertIn("args.reboot_approval_token != REBOOT_APPROVAL", self.runner)
        self.assertIn("$RebootApprovalToken -cne", self.wrapper)
        self.assertIn("[switch]$RebootValidate", self.wrapper)
        self.assertIn("if args.reboot_validate:", self.runner)
        self.assertIn("'--reboot-validate'", self.wrapper)

    def test_reboot_sequence_and_post_reboot_validation(self):
        tasks = self.reboot["tasks"]
        first = tasks[0]["ansible.builtin.reboot"]
        self.assertLessEqual(first["reboot_timeout"], 900)
        self.assertGreaterEqual(first["connect_timeout"], 5)
        checks = PLAYBOOK.read_text(encoding="utf-8")
        for evidence in ("is-active", "is-enabled", "net.ipv4.ip_forward",
                         "net.bridge.bridge-nf-call-iptables", "/sys/module/overlay",
                         "/sys/module/br_netfilter", "ctr, plugins, ls",
                         "STAGE42_REBOOT_VERIFIED"):
            if evidence == "STAGE42_REBOOT_VERIFIED":
                self.assertIn(evidence, self.runner)
            else:
                self.assertIn(evidence, checks)

    def test_no_other_reboot_modules(self):
        names = [t["name"] for t in self.reboot["tasks"]]
        self.assertEqual(sum("ansible.builtin.reboot" in t for t in self.reboot["tasks"]), 1)
        self.assertFalse(any("ansible.builtin.shell" in t for p in self.plays for t in p["tasks"]))
        self.assertTrue(any("Assert persisted container runtime health" == n for n in names))


if __name__ == "__main__":
    unittest.main()
