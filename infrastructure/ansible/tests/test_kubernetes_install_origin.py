"""Regression coverage for actual apt-cache policy formatting, including missing slash."""
import re
import unittest
from pathlib import Path

import yaml

PLAYBOOKS = Path(__file__).resolve().parents[1] / "playbooks"
POLICY = """kubeadm:
  Installed: (none)
  Candidate: 1.37.2-1.1
  Version table:
     1.37.2-1.1 500
        500 https://pkgs.k8s.io/core:/stable:/v1.37/deb  Packages
"""


class KubernetesInstallOriginTests(unittest.TestCase):
    def test_origin_assertions_accept_real_apt_cache_output(self):
        for filename in ("70-kubernetes-install-plan.yml", "80-kubernetes-package-install.yml"):
            with self.subTest(playbook=filename):
                plays = yaml.safe_load((PLAYBOOKS / filename).read_text(encoding="utf-8"))
                assertions = [
                    statement
                    for play in plays for task in play["tasks"]
                    if "ansible.builtin.assert" in task
                    for statement in task["ansible.builtin.assert"]["that"]
                    if isinstance(statement, str) and "item.stdout is search(" in statement
                    and "pkgs[.]k8s[.]io" in statement
                ]
                self.assertEqual(len(assertions), 1)
                match = re.fullmatch(r"item[.]stdout is search\('([^']+)'\)", assertions[0])
                self.assertIsNotNone(match)
                regex = match.group(1)
                self.assertIsNotNone(re.search(regex, POLICY))
                self.assertIsNone(re.search(regex, POLICY.replace("pkgs.k8s.io", "untrusted.example")))
                self.assertIsNone(re.search(regex, POLICY.replace("/v1.37/", "/v1.36/")))


if __name__ == "__main__":
    unittest.main()
