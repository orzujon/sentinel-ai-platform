"""Offline unit tests for KVP recovery pinned to the RUNNING Hyper-V kernel."""
import pathlib
import subprocess
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "src" / "worker-replica-kvp-kernel-recovery.sh"

VALID = """NOTE: This is only a simulation!
Reading package lists...
Building dependency tree...
Reading state information...
The following additional packages will be installed:
  linux-cloud-tools-7.0.0-38
The following NEW packages will be installed:
  linux-cloud-tools-7.0.0-38 linux-cloud-tools-7.0.0-38-generic
0 upgraded, 2 newly installed, 0 to remove and 29 not upgraded.
Inst linux-cloud-tools-7.0.0-38 (7.0.0-38.38 Ubuntu:26.04/resolute-updates [amd64])
Inst linux-cloud-tools-7.0.0-38-generic (7.0.0-38.38 Ubuntu:26.04/resolute-updates [amd64])
Conf linux-cloud-tools-7.0.0-38 (7.0.0-38.38 Ubuntu:26.04/resolute-updates [amd64])
Conf linux-cloud-tools-7.0.0-38-generic (7.0.0-38.38 Ubuntu:26.04/resolute-updates [amd64])
"""


def validate(simulation: str):
    return subprocess.run(
        ["bash", str(SCRIPT), "validate-simulation"],
        input=simulation,
        text=True,
        capture_output=True,
        check=False,
    )


class KernelRecoverySafetyTests(unittest.TestCase):
    def test_shell_syntax(self):
        result = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_two_approved_packages(self):
        result = validate(VALID)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("KVP_KERNEL_SIMULATION_PASS", result.stdout)

    def test_kernel_upgrade_rejected(self):
        result = validate(VALID + "Inst linux-image-7.0.0-42-generic (7.0.0-42.42 Ubuntu [amd64])\n")
        self.assertNotEqual(result.returncode, 0)

    def test_unapproved_tools_package_rejected(self):
        result = validate(VALID + "Inst linux-tools-7.0.0-38-generic (7.0.0-38.38 Ubuntu [amd64])\n")
        self.assertNotEqual(result.returncode, 0)

    def test_package_removal_rejected(self):
        result = validate(VALID + "Rem linux-cloud-tools-common [7.0.0-42.42]\n")
        self.assertNotEqual(result.returncode, 0)

    def test_mismatch_version_rejected(self):
        result = validate(VALID.replace(
            "Inst linux-cloud-tools-7.0.0-38-generic (7.0.0-38.38",
            "Inst linux-cloud-tools-7.0.0-38-generic (7.0.0-42.42",
        ))
        self.assertNotEqual(result.returncode, 0)

    def test_missing_dependency_rejected(self):
        result = validate("\n".join(
            line for line in VALID.splitlines()
            if not line.startswith("Inst linux-cloud-tools-7.0.0-38 (")
        ))
        self.assertNotEqual(result.returncode, 0)

    def test_duplicate_package_rejected(self):
        result = validate(VALID + "Conf linux-cloud-tools-7.0.0-38 (7.0.0-38.38 Ubuntu [amd64])\n")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
