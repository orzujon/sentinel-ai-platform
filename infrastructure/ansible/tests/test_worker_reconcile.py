"""Stage 4.3.5 worker reconciliation safety contract (offline)."""
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "playbooks" / "130-reconcile-worker.yml"


class WorkerJoinContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plays = yaml.safe_load(WORKER.read_text(encoding="utf-8"))
        cls.tasks = {
            task["name"]: task
            for play in cls.plays
            for task in play["tasks"]
        }

    def test_play_order_preserves_control_plane_before_join(self):
        self.assertEqual(
            [p["hosts"] for p in self.plays],
            ["sentinel_workers", "sentinel_control_plane",
             "sentinel_workers", "sentinel_control_plane"],
        )

    def test_token_only_generated_for_approved_missing_worker(self):
        task = self.tasks["Create 10-minute bootstrap credential on control plane"]
        self.assertTrue(task["no_log"])
        self.assertIn("--ttl", task["ansible.builtin.command"]["argv"])
        self.assertIn("10m", task["ansible.builtin.command"]["argv"])
        self.assertIn("sentinel_reconcile_mode == 'apply'", task["when"])
        self.assertIn("sentinel_worker_join_required | bool", task["when"])
        self.assertTrue(self.tasks["Parse endpoint, short-lived token and CA hash only into private Ansible facts"]["no_log"])

    def test_join_does_not_write_credentials_or_rejoin_existing_worker(self):
        join = self.tasks["Perform approved join without exposing token or writing a join file"]
        self.assertTrue(join["no_log"])
        cmd = join["ansible.builtin.command"]
        self.assertEqual(cmd["argv"], ["kubeadm", "join", "--config", "/dev/stdin"])
        self.assertIn("caCertHashes:", cmd["stdin"])
        self.assertIn("kubeletExtraArgs:", cmd["stdin"])
        self.assertIn("sentinel_worker_join_required | bool", join["when"][-1])
        self.assertIn("sentinel_reconcile_mode == 'apply'", join["when"])

    def test_partial_join_is_blocked_without_reset(self):
        self.assertIn(
            "Require consistent local and control-plane worker state", self.tasks
        )
        commands = [
            task.get("ansible.builtin.command", {})
            for task in self.tasks.values()
        ]
        for command in commands:
            self.assertNotIn("reset", str(command))

    def test_post_join_requires_ready_and_private_ip(self):
        ready = self.tasks["Wait for worker to register and become Ready when applying"]
        self.assertEqual(ready["until"], "worker_ready.rc == 0 and worker_ready.stdout == 'True'")
        self.assertIn("Ensure worker reports its configured private IP", self.tasks)


if __name__ == "__main__":
    unittest.main()
