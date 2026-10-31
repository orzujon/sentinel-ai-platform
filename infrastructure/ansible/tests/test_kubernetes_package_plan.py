"""Read-only Stage 4.3.2 source plan must never register sources or install packages."""
from pathlib import Path
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from run_readiness import (
    Stage4Blocked, STAGE432_MINOR, STAGE432_PATCH_CANDIDATE,
    STAGE432_REPO_URL, validate_kubernetes_package_source_plan,
)

PLAYBOOK = ROOT / "playbooks" / "50-kubernetes-package-source-plan.yml"


def sample():
    return {
        "aptSourceExists": False,
        "aptKeyringExists": False,
        "caCertificatesInstalled": True,
        "curlInstalled": True,
        "gpgInstalled": True,
        "packageHolds": [],
        "repoTlsReachable": True,
    }


class KubernetesSourcePlanTests(unittest.TestCase):
    def test_exact_official_repo_and_patch_are_proposals(self):
        self.assertEqual(STAGE432_MINOR, "v1.37")
        self.assertEqual(STAGE432_PATCH_CANDIDATE, "v1.37.1")
        self.assertEqual(
            STAGE432_REPO_URL,
            "https://pkgs.k8s.io/core:/stable:/v1.37/deb/",
        )

    def test_positive_read_only_plan(self):
        self.assertEqual(validate_kubernetes_package_source_plan(sample()), {
            "curlAvailable": True, "gpgAvailable": True,
        })

    def test_missing_install_tools_are_reported_not_silently_installed(self):
        data = sample()
        data["curlInstalled"] = False
        data["gpgInstalled"] = False
        self.assertEqual(validate_kubernetes_package_source_plan(data), {
            "curlAvailable": False, "gpgAvailable": False,
        })

    def test_unknown_source_files_trust_or_network_failure_block(self):
        for key in (
            "aptSourceExists", "aptKeyringExists",
            "caCertificatesInstalled", "repoTlsReachable",
        ):
            data = sample()
            data[key] = not data[key]
            with self.subTest(key=key), self.assertRaises(Stage4Blocked):
                validate_kubernetes_package_source_plan(data)

    def test_existing_kubernetes_holds_block(self):
        data = sample()
        data["packageHolds"] = ["kubeadm"]
        with self.assertRaises(Stage4Blocked):
            validate_kubernetes_package_source_plan(data)

    def test_schema_is_strict(self):
        data = sample()
        data["aptSourceExists"] = "False"
        with self.assertRaises(Stage4Blocked):
            validate_kubernetes_package_source_plan(data)

    def test_repo_install_is_separate_approved_aptonly_playbook(self):
        playbook = ROOT / "playbooks" / "60-kubernetes-repository.yml"
        text = playbook.read_text(encoding="utf-8")
        plays = yaml.safe_load(text)
        self.assertEqual(len(plays), 2)
        self.assertTrue(all(p["hosts"] == "sentinel_sandbox" for p in plays))
        self.assertTrue(all(p["any_errors_fatal"] for p in plays))
        self.assertEqual(plays[1]["serial"], 1)
        allowed = {
            "ansible.builtin.assert", "ansible.builtin.command",
            "ansible.builtin.stat", "ansible.builtin.uri",
            "ansible.builtin.file", "ansible.builtin.copy",
            "ansible.builtin.apt", "ansible.builtin.debug",
        }
        tasks = [t for p in plays for t in p["tasks"]]
        for task in tasks:
            modules = {k for k in task if k.startswith("ansible.builtin.")}
            self.assertEqual(len(modules), 1, task["name"])
            self.assertTrue(modules.issubset(allowed), task["name"])
            self.assertNotIn("ansible.builtin.shell", task)
            self.assertNotIn("ansible.builtin.reboot", task)
        self.assertIn("sentinel_repo_bootstrap_approved is sameas true", text)
        self.assertIn("DE15B14486CD377B9E876E1A234654DA9A296436", text)
        self.assertIn("signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg", text)
        self.assertNotIn("apt-key", text)
        self.assertNotIn("kubeadm init", text)
        self.assertNotIn("kubeadm join", text)
        for task in tasks:
            if task.get("delegate_to") == "localhost":
                self.assertIs(task["become"], False)
                self.assertIs(task["no_log"], True)
            if "ansible.builtin.apt" in task:
                self.assertIs(task["ansible.builtin.apt"]["update_cache"], True)
                self.assertNotIn("name", task["ansible.builtin.apt"])

    def test_discovery_playbook_remote_modules_non_mutating(self):
        plays = yaml.safe_load(PLAYBOOK.read_text(encoding="utf-8"))
        self.assertEqual(len(plays), 1)
        p = plays[0]
        self.assertEqual(p["hosts"], "sentinel_sandbox")
        self.assertEqual(p["serial"], 1)
        self.assertTrue(p["any_errors_fatal"])
        self.assertNotIn("become", p)
        allowed = {
            "ansible.builtin.stat", "ansible.builtin.command",
            "ansible.builtin.uri", "ansible.builtin.assert",
            "ansible.builtin.copy", "ansible.builtin.debug",
        }
        for task in p["tasks"]:
            actual = {key for key in task if key.startswith("ansible.builtin.")}
            self.assertEqual(len(actual), 1, task["name"])
            module = actual.pop()
            self.assertIn(module, allowed, task["name"])
            self.assertNotEqual(task.get("become"), True)
            if module == "ansible.builtin.command":
                self.assertIs(task["changed_when"], False)
            if module == "ansible.builtin.uri":
                options = task[module]
                self.assertIs(options["validate_certs"], True)
                self.assertEqual(options["method"], "GET")
                self.assertIs(options["return_content"], False)
                self.assertIs(task["changed_when"], False)
            if module == "ansible.builtin.copy":
                self.assertEqual(task["delegate_to"], "localhost")
                self.assertIs(task["become"], False)
                self.assertIs(task["no_log"], True)
                self.assertEqual(task[module]["mode"], "0600")


if __name__ == "__main__":
    unittest.main()
