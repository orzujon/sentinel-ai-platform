"""Regression tests for parsing raw apt-cache policy (not Ansible fallback text)."""
from pathlib import Path
import importlib.util
import unittest

FILE = Path(__file__).resolve().parents[1] / "run_readiness.py"
spec = importlib.util.spec_from_file_location("apt_candidate_runner", FILE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class AptCandidateParsing(unittest.TestCase):
    def test_regular_ubuntu_package_candidate(self):
        policy = (
            "containerd:\n"
            "  Installed: (none)\n"
            "  Candidate: 2.2.2-0ubuntu1.1\n"
            "  Version table:\n"
            "     2.2.2-0ubuntu1.1 500\n"
        )
        self.assertEqual(mod.parse_apt_candidate(policy), "2.2.2-0ubuntu1.1")

    def test_missing_candidate_blocks(self):
        policy = "containerd:\n  Installed: (none)\n  Candidate: (none)\n"
        self.assertIsNone(mod.parse_apt_candidate(policy))
        self.assertIsNone(mod.parse_apt_candidate(""))
        self.assertIsNone(mod.parse_apt_candidate("containerd:\n  Installed: (none)\n"))

    def test_wrong_fields_do_not_create_candidate(self):
        self.assertIsNone(mod.parse_apt_candidate(
            "containerd:\n  Installed: 2.2.2-0ubuntu1\n  Version table:\n"
        ))

    def test_duplicate_policy_is_ambiguous(self):
        self.assertIsNone(mod.parse_apt_candidate(
            "  Candidate: 2.2.2-0ubuntu1\n  Candidate: 2.2.2-0ubuntu2\n"
        ))

    def test_prevent_unexpected_candidate_content(self):
        self.assertIsNone(mod.parse_apt_candidate("  Candidate: version;echo\n"))
        self.assertIsNone(mod.parse_apt_candidate("  Candidate: (none)\n"))


if __name__ == "__main__":
    unittest.main()
