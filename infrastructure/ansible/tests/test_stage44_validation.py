"""Stage 4.4 acceptance checks must not change an existing cluster."""
import unittest
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
PLAYBOOK = ROOT / "playbooks" / "140-cluster-validate.yml"


class Stage44Contract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plays = yaml.safe_load(PLAYBOOK.read_text(encoding="utf-8"))
        cls.tasks = cls.plays[0]["tasks"]

    def test_read_only_validation_uses_only_pinned_control_plane(self):
        self.assertEqual(len(self.plays), 1)
        self.assertEqual(self.plays[0]["hosts"], "sentinel_control_plane")
        self.assertTrue(self.plays[0]["any_errors_fatal"])
        allowed = {"ansible.builtin.command", "ansible.builtin.assert",
                   "ansible.builtin.set_fact", "ansible.builtin.debug"}
        for task in self.tasks:
            self.assertTrue(set(task) - {"name", "register", "changed_when"} <= allowed, task["name"])
            if "ansible.builtin.command" in task:
                self.assertIs(task["changed_when"], False)
                argv = task["ansible.builtin.command"]["argv"]
                self.assertEqual(argv[0], "kubectl")
                self.assertIn("get", argv)
                self.assertNotIn("delete", argv)
                self.assertNotIn("apply", argv)

    def test_required_acceptance_evidence_and_no_false_traffic_claim(self):
        tasks = {task["name"]: task for task in self.tasks}
        self.assertIn("Require exactly two expected Ready nodes with pinned versions and private IPs", tasks)
        self.assertIn("Require healthy CoreDNS deployment and ready endpoint", tasks)
        self.assertIn("Require Flannel DaemonSet scheduled and Ready on both nodes", tasks)
        report = tasks["Report Stage 4.4 evidence without claiming active traffic tests"]
        lines = report["ansible.builtin.debug"]["msg"]
        self.assertTrue(any("TRAFFIC_TEST: NOT_RUN" in text for text in lines))
        self.assertTrue(any("RECOVERY_TEST: NOT_RUN" in text for text in lines))


if __name__ == "__main__":
    unittest.main()
