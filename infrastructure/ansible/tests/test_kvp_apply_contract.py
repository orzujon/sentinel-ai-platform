"""Offline safety contracts for the Stage 5.3 fresh-only KVP install playbook."""
from pathlib import Path
import unittest

import yaml

PLAYBOOK = Path(__file__).resolve().parents[1] / "playbooks" / "36-hyperv-kvp-package-apply.yml"


class KvpApplySafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plays = yaml.safe_load(PLAYBOOK.read_text(encoding="utf-8"))

    def test_all_node_preflight_before_serial_apply(self):
        self.assertEqual(len(self.plays), 2)
        first, second = self.plays
        self.assertEqual(first["hosts"], "sentinel_sandbox")
        self.assertEqual(second["hosts"], "sentinel_sandbox")
        self.assertTrue(first["any_errors_fatal"])
        self.assertTrue(second["any_errors_fatal"])
        self.assertEqual(second["serial"], 1)
        self.assertTrue(first["gather_facts"])

    def test_mutations_only_in_second_play_after_approval(self):
        first, second = self.plays
        for task in first["tasks"]:
            self.assertNotIn("ansible.builtin.apt", task)
            self.assertNotIn("ansible.builtin.systemd_service", task)
        tasks = second["tasks"]
        self.assertIn("ansible.builtin.assert", tasks[0])
        approved = tasks[0]["ansible.builtin.assert"]["that"]
        for requirement in ("sentinel_fresh_bootstrap", "sentinel_kvp_install_approved",
                            "sentinel_kvp_ssh_identity_verified"):
            self.assertTrue(any(requirement in item for item in approved))
        self.assertIn("ansible.builtin.apt", tasks[1])
        self.assertIn("ansible.builtin.systemd_service", tasks[2])

    def test_existing_kubernetes_state_is_blocked(self):
        tasks = self.plays[0]["tasks"]
        self.assertTrue(any("ansible.builtin.stat" in task and
                            any("/etc/kubernetes/" in x or "/var/lib/kubelet/" in x
                                for x in task["ansible.builtin.stat"]["loop"])
                            for task in tasks if "ansible.builtin.stat" in task))
        self.assertTrue(any("existing Kubernetes" in str(task.get("name", "")) for task in tasks))
        self.assertTrue(any("Kubernetes state" in str(task.get("ansible.builtin.assert", {}).get("fail_msg", ""))
                            for task in tasks))

    def test_install_is_pinned_and_does_not_refresh_cache(self):
        task = next(t["ansible.builtin.apt"] for t in self.plays[1]["tasks"]
                    if "ansible.builtin.apt" in t)
        self.assertIn("linux-cloud-tools-common=", task["name"])
        self.assertFalse(task["update_cache"])
        self.assertFalse(task["allow_downgrade"])
        self.assertFalse(task["allow_change_held_packages"])
        self.assertTrue(task["fail_on_autoremove"])


if __name__ == "__main__":
    unittest.main()
