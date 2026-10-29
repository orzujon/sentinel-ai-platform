"""Cross-platform package/contract checks; does not execute PowerShell or touch Hyper-V."""
import ipaddress
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class SentinelContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cfg = json.loads((ROOT / 'config/lab.json').read_text())
        cls.stages = json.loads((ROOT / 'config/stages.json').read_text())['stages']

    def test_sandbox_does_not_target_existing_vms(self):
        protected = set(self.cfg['protection']['vmNames'])
        future = {vm['name'] for vm in self.cfg['vms']}
        self.assertTrue(protected.isdisjoint(future))
        self.assertTrue(all(name.startswith('sentinel-l1-') for name in future))

    def test_static_ip_separation(self):
        future = ipaddress.ip_network(self.cfg['network']['subnet'])
        for protected in self.cfg['protection']['subnets']:
            self.assertFalse(future.overlaps(ipaddress.ip_network(protected)))
        endpoints = [self.cfg['network']['hostIP']] + [vm['staticIP'] for vm in self.cfg['vms']]
        self.assertEqual(len(endpoints), len(set(endpoints)))
        self.assertTrue(all(ipaddress.ip_address(ip) in future for ip in endpoints))

    def test_stage_graph_has_preflight_first_and_is_acyclic(self):
        ids = [x['id'] for x in self.stages]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(ids[0], '00-preflight')
        self.assertEqual([x['id'] for x in self.stages if x['implemented']], ['00-preflight'])
        completed = set()
        for stage in self.stages:
            self.assertTrue(set(stage['dependsOn']).issubset(completed))
            completed.add(stage['id'])

    def test_preflight_never_calls_hyperv_mutations(self):
        code = (ROOT / 'src/Sentinel.Preflight.psm1').read_text()
        # Source-code guard only, not a substitute for running PowerShell parser tests.
        for cmd in ('New-VM', 'Stop-VM', 'Start-VM', 'Remove-VM', 'New-VMSwitch',
                    'Remove-VMSwitch', 'Enable-WindowsOptionalFeature', 'Set-VM',
                    'Set-NetIPAddress', 'New-NetIPAddress', 'kubeadm reset'):
            self.assertFalse(re.search(r'^\s*' + re.escape(cmd) + r'\b', code, re.M | re.I), cmd)

    def test_nonsecret_config(self):
        text = (ROOT / 'config/lab.json').read_text().lower()
        for key in ('private_key', 'access_token', 'password', 'client_secret'):
            self.assertNotIn('"' + key + '"', text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
