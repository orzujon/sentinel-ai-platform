"""Read-only config safety tests. No GitHub, Hyper-V, Vault or VM access."""
import copy
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FILE = ROOT / "config" / "plan.py"
spec = importlib.util.spec_from_file_location("sentinel_config_plan", FILE)
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)

VALID = """
apiVersion: infra.sentinel.dev/v1alpha1
kind: SentinelEnvironment
metadata:
  name: lab
spec:
  provider: hyperv
  mode: isolated-sandbox
  provisioningEnabled: false
  host:
    vmRoot: 'C:\\Sentinel\\Level1-Sandbox\\VMs'
    imageCache: 'C:\\Sentinel\\ImageCache'
    wslDistribution: Ubuntu-26.04
  image:
    distribution: Ubuntu
    architecture: amd64
    buildId: '20261016'
    sourceUrl: https://cloud-images.ubuntu.com/releases/26.04/release-20261016/ubuntu-26.04-server-cloudimg-amd64.img
    expectedSha256: null
  network:
    managementSwitch: Default Switch
    privateSwitch: Sentinel-L1
    type: Internal
    subnet: 10.78.0.0/24
    hostIP: 10.78.0.1
  vms:
    - name: sentinel-l1-cp01
      role: control-plane
      staticIP: 10.78.0.10
      virtualProcessors: 2
      memoryGB: 4
      diskGB: 60
    - name: sentinel-l1-w01
      role: worker
      staticIP: 10.78.0.11
      virtualProcessors: 2
      memoryGB: 4
      diskGB: 60
  capacity:
    hostRAMReserveGB: 4
    hostLogicalCPUReserve: 4
    diskReserveGB: 20
  protection:
    vmNames: [k8s-cp01, k8s-w01]
    switchNames: [Sentinel-K8s, Default Switch]
    subnets: [10.77.0.0/24]
  identity:
    username: orzu
    sshPublicKeyRef: local-user-ed25519-pub
  secretRefs: {}
"""


class TestConfiguration(unittest.TestCase):
    def setUp(self):
        self.cfg = plan.parse_yaml(VALID)

    def test_read_only_plan(self):
        result = plan.build_plan(self.cfg, "abc" * 13 + "a", "lab")
        self.assertEqual(result["status"], "PLAN_ONLY")
        self.assertEqual(result["mutations"], 0)
        self.assertFalse(result["deploymentPermitted"])
        self.assertEqual(result["vmCount"], 2)
        self.assertFalse(result["imageDigestPinned"])
        self.assertNotIn("secretRefs", result)

    def test_reproducible_digest(self):
        a = plan.build_plan(self.cfg, "a" * 40, "lab")
        b = plan.build_plan(self.cfg, "a" * 40, "lab")
        self.assertEqual(a["planSha256"], b["planSha256"])

    def test_duplicate_yaml_keys_fail(self):
        with self.assertRaises(plan.ConfigError):
            plan.parse_yaml("key: first\nkey: second\n")

    def test_yaml_python_object_not_executed(self):
        with self.assertRaises(plan.ConfigError):
            plan.parse_yaml("!!python/object/apply:os.system ['whoami']")

    def test_protected_subnet_fails(self):
        self.cfg["spec"]["network"]["subnet"] = "10.77.0.0/24"
        with self.assertRaises(plan.ConfigError):
            plan.validate(self.cfg)

    def test_protected_vm_cannot_be_removed_from_policy(self):
        self.cfg["spec"]["protection"]["vmNames"] = []
        with self.assertRaises(plan.ConfigError):
            plan.validate(self.cfg)

    def test_duplicate_ip_fails(self):
        self.cfg["spec"]["vms"][1]["staticIP"] = "10.78.0.10"
        with self.assertRaises(plan.ConfigError):
            plan.validate(self.cfg)

    def test_unknown_fields_fail(self):
        self.cfg["spec"]["runCommand"] = "Remove-VM"
        with self.assertRaises(plan.ConfigError):
            plan.validate(self.cfg)

    def test_non_bool_provisioning_flag_fails(self):
        self.cfg["spec"]["provisioningEnabled"] = "true"
        with self.assertRaises(plan.ConfigError):
            plan.validate(self.cfg)

    def test_secrets_are_not_in_plan(self):
        self.cfg["spec"]["secretRefs"] = {"db": "vault://sentinel/lab/db"}
        result = plan.build_plan(self.cfg, "b" * 40, "lab")
        self.assertNotIn("vault://", str(result))

    def test_private_key_value_is_rejected(self):
        self.cfg["spec"]["secretRefs"] = {"db": "literal-plaintext-password"}
        with self.assertRaises(plan.ConfigError):
            plan.validate(self.cfg)

    def test_path_traversal_fails(self):
        self.cfg["spec"]["host"]["vmRoot"] = "C:\\Sentinel\\Level1-Sandbox\\..\\VMs"
        with self.assertRaises(plan.ConfigError):
            plan.validate(self.cfg)


if __name__ == "__main__":
    unittest.main()
