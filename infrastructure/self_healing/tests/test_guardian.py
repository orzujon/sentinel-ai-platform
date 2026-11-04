"""Sentinel Guardian 1st self-heal experiment. All tests offline / no Kubernetes."""
from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SRC = Path(__file__).resolve().parents[1] / "guardian.py"
spec = importlib.util.spec_from_file_location("sentinel_guardian", SRC)
guardian = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guardian)


def snapshot(*, replicas=0, available=0):
    return {
        "nodes": {
            "items": [
                {"metadata": {"name": name},
                 "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
                for name in sorted(guardian.NODES)
            ]
        },
        "namespace": {"metadata": {
            "name": guardian.NAMESPACE,
            "uid": "11111111-1111-4111-8111-111111111111",
            "resourceVersion": "300",
            "labels": {guardian.MARKER: "true"},
        }},
        "deployment": {
            "metadata": {
                "name": guardian.DEPLOYMENT,
                "namespace": guardian.NAMESPACE,
                "uid": "22222222-2222-4222-8222-222222222222",
                "resourceVersion": "400",
                "labels": {guardian.MARKER: "true"},
                "annotations": {"sentinel.ai/desired-replicas": "1"},
            },
            "spec": {
                "replicas": replicas,
                "selector": {"matchLabels": {"app": guardian.DEPLOYMENT}},
                "template": {"metadata": {"labels": {"app": guardian.DEPLOYMENT}}}
            },
            "status": {"availableReplicas": available},
        }
    }


def args(**kwargs):
    values = dict(mode="plan", context="sentinel-fresh", snapshot=None, approval=None,
                  expected_plan=None, expected_namespace_uid=None,
                  expected_deployment_uid=None)
    values.update(kwargs)
    return type("Args", (), values)()


class GuardianTests(unittest.TestCase):
    def test_exact_failure_proposes_single_allowed_action(self):
        plan = guardian.create_plan(snapshot())
        self.assertEqual(plan["decision"], "PROPOSE_SCALE_TO_ONE")
        self.assertEqual(plan["fixedDesiredReplicas"], 1)
        self.assertTrue(plan["humanApprovalRequired"])
        self.assertRegex(plan["planSHA256"], r"^[0-9a-f]{64}$")
        self.assertEqual(plan, guardian.create_plan(snapshot()))

    def test_healthy_and_unusual_cases_never_propose_mutation(self):
        self.assertEqual(guardian.create_plan(snapshot(replicas=1, available=1))["decision"], "HEALTHY")
        for replicas, available in [(1, 0), (2, 2), (0, 1), (3, 0)]:
            self.assertEqual(guardian.create_plan(
                snapshot(replicas=replicas, available=available))["decision"], "ABSTAIN")

    def test_wrong_or_unready_cluster_never_heals(self):
        for change in ("node", "unready", "extra"):
            state = snapshot()
            if change == "node":
                state["nodes"]["items"][0]["metadata"]["name"] = "sentinel-l1-cp01"
            elif change == "unready":
                state["nodes"]["items"][0]["status"]["conditions"][0]["status"] = "False"
            else:
                state["nodes"]["items"].append({"metadata": {"name": "other"}, "status": {}})
            with self.subTest(change=change), self.assertRaises(guardian.Blocked):
                guardian.create_plan(state)

    def test_missing_scope_identity_or_intent_blocks(self):
        for mutation in (
            lambda s: s["namespace"]["metadata"]["labels"].clear(),
            lambda s: s["deployment"]["metadata"]["labels"].clear(),
            lambda s: s["deployment"]["metadata"]["annotations"].clear(),
            lambda s: s["deployment"]["metadata"].update(uid=""),
            lambda s: s["deployment"]["metadata"].update(namespace="default"),
            lambda s: s["deployment"]["spec"]["selector"]["matchLabels"].update(app="payments-api"),
            lambda s: s["namespace"]["metadata"].update(deletionTimestamp="now"),
            lambda s: s["deployment"]["metadata"].update(resourceVersion="unknown"),
        ):
            state = snapshot()
            mutation(state)
            with self.assertRaises(guardian.Blocked):
                guardian.create_plan(state)

    def test_identity_or_version_change_changes_plan_hash(self):
        state = snapshot()
        original = guardian.create_plan(state)["planSHA256"]
        for where, field, value in (
            ("namespace", "uid", "33333333-3333-4333-8333-333333333333"),
            ("deployment", "uid", "44444444-4444-4444-8444-444444444444"),
            ("deployment", "resourceVersion", "401"),
        ):
            changed = copy.deepcopy(state)
            changed[where]["metadata"][field] = value
            self.assertNotEqual(original, guardian.create_plan(changed)["planSHA256"])

    def test_plan_uses_observation_only(self):
        with patch.object(guardian, "fetch_snapshot", return_value=snapshot()), \
             patch.object(guardian, "scale_exact_demo") as scale:
            self.assertEqual(guardian.execute(args()), 0)
            scale.assert_not_called()

    def test_apply_does_not_accept_offline_snapshots_or_wrong_approval(self):
        plan = guardian.create_plan(snapshot())
        for fields in (
            {"approval": None},
            {"approval": "HEAL_PRODUCTION"},
            {"snapshot": "/tmp/fake.json"},
            {"expected_plan": "0" * 64},
            {"expected_namespace_uid": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"},
            {"expected_deployment_uid": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"},
        ):
            settings = dict(mode="apply", approval=guardian.APPROVAL,
                            expected_plan=plan["planSHA256"],
                            expected_namespace_uid=plan["namespaceUID"],
                            expected_deployment_uid=plan["deploymentUID"])
            settings.update(fields)
            with self.subTest(fields=fields), \
                 patch.object(guardian, "scale_exact_demo") as scale, \
                 patch.object(guardian, "fetch_snapshot", return_value=snapshot()), \
                 self.assertRaises(guardian.Blocked):
                guardian.execute(args(**settings))
                scale.assert_not_called()

    def test_apply_one_guarded_scale_and_observe_postcondition(self):
        before = snapshot()
        after = snapshot(replicas=1, available=0)
        after["deployment"]["metadata"]["resourceVersion"] = "401"
        plan = guardian.create_plan(before)
        with patch.object(guardian, "fetch_snapshot", side_effect=[before, after]) as fetch, \
             patch.object(guardian, "scale_exact_demo") as scale:
            result = guardian.execute(args(
                mode="apply", approval=guardian.APPROVAL,
                expected_plan=plan["planSHA256"],
                expected_namespace_uid=plan["namespaceUID"],
                expected_deployment_uid=plan["deploymentUID"]))
            self.assertEqual(result, 0)
            scale.assert_called_once()
            self.assertEqual(fetch.call_count, 2)

    def test_apply_missing_postcondition_is_blocked_after_one_attempt(self):
        before = snapshot()
        plan = guardian.create_plan(before)
        with patch.object(guardian, "fetch_snapshot", side_effect=[before, before]), \
             patch.object(guardian, "scale_exact_demo") as scale, \
             self.assertRaises(guardian.Blocked):
            guardian.execute(args(
                mode="apply", approval=guardian.APPROVAL,
                expected_plan=plan["planSHA256"],
                expected_namespace_uid=plan["namespaceUID"],
                expected_deployment_uid=plan["deploymentUID"]))
            scale.assert_called_once()

    def test_default_fixture_read_is_offline_and_readonly(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "snapshot.json"
            path.write_text(json.dumps(snapshot()))
            with patch.object(guardian, "fetch_snapshot") as fetch, \
                 patch.object(guardian, "scale_exact_demo") as scale:
                self.assertEqual(guardian.execute(args(context=None, snapshot=str(path))), 0)
                fetch.assert_not_called()
                scale.assert_not_called()

    def test_manifest_isolated_and_no_rbac(self):
        yaml = (Path(__file__).resolve().parents[1] / "sentinel-demo.yaml").read_text()
        for token in ("sentinel-healing-lab", "sentinel-demo-api",
                      "sentinel.ai/demo-only", "automountServiceAccountToken: false",
                      "runAsNonRoot: true", "replicas: 1", "busybox:1.37.0"):
            self.assertIn(token, yaml)
        for denied in ("ClusterRole", "RoleBinding", "kind: Ingress", "hostNetwork: true"):
            self.assertNotIn(denied, yaml)


if __name__ == "__main__":
    unittest.main()
