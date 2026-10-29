"""Guardrails for Stage 4.2: read-only guests, private controller reporting."""
import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAYBOOK = ROOT / "playbooks" / "10-baseline-discovery.yml"
RUNNER = ROOT / "run_readiness.py"
WINDOWS_ENTRY = ROOT / "Invoke-SentinelReadiness.ps1"

ALLOWED_READ_ONLY = {
    "ansible.builtin.assert",
    "ansible.builtin.command",
    "ansible.builtin.debug",
    "ansible.builtin.stat",
    "ansible.builtin.copy",  # Only explicitly delegated to localhost.
}

READ_COMMANDS = {"apt-cache", "dpkg-query", "cat", "sysctl", "systemctl", "uname"}
MUTATION_TOKENS = {"apt", "apt-get", "swapoff", "sysctl -w", "modprobe", "systemctl restart"}


class BaselineDiscoveryContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.play = yaml.safe_load(PLAYBOOK.read_text(encoding="utf-8"))[0]

    def test_read_only_task_modules(self):
        self.assertEqual(self.play["hosts"], "sentinel_sandbox")
        self.assertIs(self.play["any_errors_fatal"], True)
        self.assertIs(self.play["gather_facts"], True)
        self.assertNotIn("become", self.play)
        for task in self.play["tasks"]:
            module = next(key for key in task if key.startswith("ansible.builtin."))
            self.assertIn(module, ALLOWED_READ_ONLY, task["name"])
            self.assertNotIn("become", task)
            if module == "ansible.builtin.copy":
                self.assertEqual(task.get("delegate_to"), "localhost")
                self.assertIs(task.get("no_log"), True)
                self.assertIs(task.get("become"), False)
                self.assertEqual(task[module].get("mode"), "0600")
                self.assertIn("sentinel_report_root", task[module]["dest"])
            if module == "ansible.builtin.command":
                self.assertIs(task["changed_when"], False)
                argv = task[module]["argv"]
                self.assertIn(argv[0], READ_COMMANDS)
                self.assertNotIn(argv[0], MUTATION_TOKENS)

    def test_existing_cluster_protection(self):
        content = PLAYBOOK.read_text(encoding="utf-8")
        self.assertIn("/var/lib/kubelet/config.yaml", content)
        self.assertIn("/etc/kubernetes/admin.conf", content)
        self.assertIn("Existing Kubernetes configuration found", content)

    def test_package_is_inspected_not_installed(self):
        content = PLAYBOOK.read_text(encoding="utf-8")
        self.assertIn("apt-cache", content)
        self.assertIn("Candidate:", content)
        self.assertNotIn("ansible.builtin.apt:", content)
        self.assertNotIn("ansible.builtin.service:", content)
        self.assertEqual(content.count("ansible.builtin.copy:"), 1)
        self.assertIn("delegate_to: localhost", content)
        self.assertNotIn("ansible.builtin.shell:", content)

    def test_controller_requires_opt_in_discovery(self):
        python = RUNNER.read_text(encoding="utf-8")
        powershell = WINDOWS_ENTRY.read_text(encoding="utf-8")
        self.assertIn("--discover-baseline", python)
        self.assertIn("args.discover_baseline", python)
        self.assertIn("STAGE42_DISCOVERED", python)
        self.assertIn("SENTINEL BASELINE DISCOVERY", python)
        self.assertIn("report_dir", python)
        self.assertIn("json.loads", python)
        self.assertIn("[switch]$DiscoverBaseline", powershell)
        self.assertIn("$DiscoverBaseline.IsPresent", powershell)
        self.assertNotIn("Start-VM", powershell)


if __name__ == "__main__":
    unittest.main()
