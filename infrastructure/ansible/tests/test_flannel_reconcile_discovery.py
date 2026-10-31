"""Regression: kubectl --ignore-not-found -o json may return '{}' for absent DS."""
import json
from pathlib import Path
import unittest

import yaml


PLAYBOOK = Path(__file__).resolve().parents[1] / "playbooks" / "120-reconcile-flannel.yml"


class ReconcileDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tasks = yaml.safe_load(PLAYBOOK.read_text(encoding="utf-8"))[0]["tasks"]
        cls.tasks = {task["name"]: task for task in tasks}

    def test_missing_resource_is_detected_by_kind_not_nonempty_stdout(self):
        stage = self.tasks["Determine current release from parsed Kubernetes objects"]
        expr = stage["ansible.builtin.set_fact"]["sentinel_existing_ds"]
        self.assertIn("sentinel_ds_object.kind", expr)
        self.assertNotIn("stdout | trim != ''", expr)
        for response, expected in [
            ({}, False),
            ({"kind": "DaemonSet", "metadata": {"name": "kube-flannel-ds"}}, True),
        ]:
            observed = response.get("kind", "") == "DaemonSet"
            self.assertEqual(observed, expected)

    def test_unexpected_api_response_must_fail_closed(self):
        gate = self.tasks["Require Kubernetes discovery responses to have expected resource kinds"]
        clauses = gate["ansible.builtin.assert"]["that"]
        self.assertTrue(any("DaemonSet" in c and "sentinel_ds_object" in c for c in clauses))
        self.assertTrue(any("Namespace" in c and "sentinel_namespace_object" in c for c in clauses))

    def test_existing_unmarked_daemonset_remains_blocked(self):
        gate = self.tasks["Refuse to adopt unmanaged existing workloads or silently change releases"]
        self.assertIn("not sentinel_existing_ds or sentinel_release_matches", gate["ansible.builtin.assert"]["that"])


if __name__ == "__main__":
    unittest.main()
