"""Non-destructive package checks with a synthetic, non-secret configuration."""
import ipaddress
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class SentinelContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cfg = json.loads((ROOT / "tests" / "fixtures" / "lab.json").read_text())
        cls.stages = json.loads((ROOT / "config" / "stages.json").read_text())["stages"]

    def test_isolated_lab(self):
        protected = set(self.cfg["protection"]["vmNames"])
        names = {vm["name"] for vm in self.cfg["vms"]}
        self.assertTrue(protected.isdisjoint(names))
        subnet = ipaddress.ip_network(self.cfg["network"]["subnet"])
        for item in self.cfg["protection"]["subnets"]:
            self.assertFalse(subnet.overlaps(ipaddress.ip_network(item)))
        self.assertEqual(len({vm["staticIP"] for vm in self.cfg["vms"]}), len(self.cfg["vms"]))

    def test_stage_graph_acyclic_and_ordered(self):
        done = set()
        for stage in self.stages:
            self.assertNotIn(stage["id"], done)
            self.assertTrue(set(stage["dependsOn"]).issubset(done))
            done.add(stage["id"])
        self.assertTrue(self.stages[0]["implemented"])
        self.assertTrue(next(x for x in self.stages if x["id"] == "20-image-cache")["implemented"])
        self.assertTrue(next(x for x in self.stages if x["id"] == "40-create-vms")["implemented"])

    def test_preflight_no_hyperv_mutations(self):
        code = (ROOT / "src" / "Sentinel.Preflight.psm1").read_text()
        for cmd in ("New-VM", "Stop-VM", "Start-VM", "Remove-VM", "New-VMSwitch",
                    "Remove-VMSwitch", "Enable-WindowsOptionalFeature", "Set-VM",
                    "Set-NetIPAddress", "New-NetIPAddress", "kubeadm reset"):
            self.assertFalse(re.search(r"^\s*" + re.escape(cmd) + r"\b", code, re.M | re.I), cmd)

    def test_fixture_has_no_secret_values(self):
        text = (ROOT / "tests" / "fixtures" / "lab.json").read_text().lower()
        for key in ('"private_key"', '"access_token"', '"password"', '"client_secret"'):
            self.assertNotIn(key, text)


if __name__ == "__main__":
    unittest.main()
