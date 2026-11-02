"""Offline Linux CI gate for disposable five-package KVP simulation changes."""
import pathlib
import subprocess
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "src" / "worker-replica-kvp.sh"
SIMULATION = """NOTE: This is only a simulation!
Reading package lists...
Building dependency tree...
The following packages will be upgraded:
  bpftool linux-libc-dev linux-perf linux-tools-common
4 upgraded, 1 newly installed, 0 to remove and 29 not upgraded.
Inst bpftool [7.7.0+7.0.0-38.38] (7.7.0+7.0.0-42.42 Ubuntu:26.04/resolute-updates [amd64])
Inst linux-cloud-tools-common (7.0.0-42.42 Ubuntu:26.04/resolute-updates [all])
Inst linux-libc-dev [7.0.0-38.38] (7.0.0-42.42 Ubuntu:26.04/resolute-updates [amd64])
Inst linux-perf [7.0.0-38.38] (7.0.0-42.42 Ubuntu:26.04/resolute-updates [amd64])
Inst linux-tools-common [7.0.0-38.38] (7.0.0-42.42 Ubuntu:26.04/resolute-updates [all])
Conf bpftool (7.7.0+7.0.0-42.42 Ubuntu:26.04/resolute-updates [amd64])
Conf linux-cloud-tools-common (7.0.0-42.42 Ubuntu:26.04/resolute-updates [all])
Conf linux-libc-dev (7.0.0-42.42 Ubuntu:26.04/resolute-updates [amd64])
Conf linux-perf (7.0.0-42.42 Ubuntu:26.04/resolute-updates [amd64])
Conf linux-tools-common (7.0.0-42.42 Ubuntu:26.04/resolute-updates [all])
"""


def run_simulation(simulation: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(SCRIPT), "validate-simulation"],
        input=simulation,
        text=True,
        capture_output=True,
        check=False,
    )


class WorkerReplicaKvpSimulationTests(unittest.TestCase):
    def test_bash_syntax(self):
        result = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_exact_user_observed_transaction_passes(self):
        result = run_simulation(SIMULATION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("KVP_SIMULATION_PASS", result.stdout)

    def test_additional_package_is_rejected(self):
        simulation = SIMULATION + "Inst curl (8.0.0 Ubuntu:26.04/resolute [amd64])\n"
        self.assertNotEqual(run_simulation(simulation).returncode, 0)

    def test_package_removal_is_rejected(self):
        simulation = SIMULATION + "Rem bash [5.3] [5.4 Ubuntu:26.04/resolute]\n"
        self.assertNotEqual(run_simulation(simulation).returncode, 0)

    def test_unreviewed_version_is_rejected(self):
        simulation = SIMULATION.replace("7.7.0+7.0.0-42.42 Ubuntu", "7.7.0+7.0.0-43.43 Ubuntu")
        self.assertNotEqual(run_simulation(simulation).returncode, 0)

    def test_missing_package_is_rejected(self):
        simulation = "\n".join(
            line for line in SIMULATION.splitlines()
            if not line.startswith("Inst linux-perf ")
        )
        self.assertNotEqual(run_simulation(simulation).returncode, 0)

    def test_duplicate_package_is_rejected(self):
        simulation = SIMULATION + "Inst linux-tools-common (7.0.0-42.42 Ubuntu:26.04/resolute-updates [all])\n"
        self.assertNotEqual(run_simulation(simulation).returncode, 0)


if __name__ == "__main__":
    unittest.main()
