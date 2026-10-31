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

    def test_unmarked_daemonset_requires_zero_manifest_diff(self):
        diff = self.tasks["Compare unmanaged existing Flannel to exact locked manifest with kubectl diff"]
        self.assertEqual(diff["ansible.builtin.command"]["argv"][-3:], ["diff", "-f", "/dev/stdin"])
        self.assertFalse(diff["changed_when"])
        gate = self.tasks["Refuse to overwrite a different or unverified existing Flannel deployment"]
        condition = gate["ansible.builtin.assert"]["that"][0]
        self.assertIn("sentinel_diff.rc", condition)
        self.assertIn("== 0", condition)
        adopt = self.tasks["Record whether an identical unmanaged deployment can be safely adopted"]
        self.assertIn("sentinel_diff.rc", adopt["ansible.builtin.set_fact"]["sentinel_adopt_identical"])
        annotate = self.tasks["Annotate verified release after successful rollout"]
        self.assertIn("sentinel_adopt_identical", annotate["when"][-1])

    def test_release_drift_cannot_trigger_apply(self):
        mutation = self.tasks["Apply exact cached manifest only when absent and approved"]
        self.assertIn("not sentinel_existing_ds", mutation["when"])
        self.assertIn("sentinel_reconcile_mode == 'apply'", mutation["when"])


if __name__ == "__main__":
    unittest.main()
