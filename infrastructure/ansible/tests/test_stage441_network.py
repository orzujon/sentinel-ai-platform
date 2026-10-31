"""Contract checks for active networking test isolation."""
import unittest
from pathlib import Path
import yaml

PATH = Path(__file__).resolve().parents[1] / "playbooks" / "150-active-network.yml"


class ActiveNetworkSafety(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tasks = yaml.safe_load(PATH.read_text(encoding="utf-8"))[0]["tasks"]
        cls.top = {t["name"]: t for t in tasks}
        cls.probe = cls.top["Run temporary cross-node probes with guaranteed guarded cleanup"]

    def test_approval_and_plan_gate(self):
        self.assertIn("sentinel_reconcile_mode == 'apply'", self.probe["when"])
        self.assertIn("sentinel_network_test_enabled | bool", self.probe["when"])
        self.assertIn("sentinel_reconcile_approved", str(self.top["Require explicit lab approval for active diagnostic Pods"]))

    def test_owned_namespace_and_cleanup(self):
        steps = {t["name"]: t for t in self.probe["block"]}
        create = steps["Create unique owned diagnostic namespace without altering existing namespaces"]
        self.assertIn("sentinel.ai/run-id:", create["ansible.builtin.command"]["stdin"])
        cleanup = {t["name"]: t for t in self.probe["always"]}
        self.assertIn("sentinel.ai/run-id", str(cleanup["Require precise current run ownership marker"]))
        self.assertIn("sentinel_netcheck_created", str(cleanup["Remove only this run's owned diagnostic namespace"]))

    def test_network_checks_in_both_directions(self):
        names = [t["name"] for t in self.probe["block"]]
        for name in ("Probe Kubernetes DNS from control-plane Pod",
                     "Probe Kubernetes DNS from worker Pod",
                     "Test worker to control-plane direct Pod IP connection",
                     "Test control-plane to worker direct Pod IP connection",
                     "Test Service DNS and ClusterIP HTTP routing from worker Pod"):
            self.assertIn(name, names)


if __name__ == "__main__":
    unittest.main()
