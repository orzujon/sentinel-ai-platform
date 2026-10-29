# Proposed SentinelEnvironment YAML contract — v1alpha1

**Status: design only.** Current `sentinel.ps1` still loads local `config/lab.json`; neither a YAML loader nor a secret manager is implemented. Do not pass these examples to the current provisioning commands.

## Repository ownership

| Information | Source | Example |
|---|---|---|
| Provisioning code | Public platform repo | `src/Sentinel.Infrastructure.psm1` |
| Schema/policy logic | Public platform repo | Future `schemas/sentinel-environment-v1alpha1.json` |
| Deployment values | Private config repo | `environments/lab.yaml` |
| Secret **references** | Private config repo | `vault://sentinel/lab/...` |
| Secret **values** | Dedicated secret store | Never in Git |

## Shape

```yaml
apiVersion: infra.sentinel.dev/v1alpha1
kind: SentinelEnvironment
metadata:
  name: lab
spec:
  provider: hyperv
  mode: isolated-sandbox
  provisioningEnabled: false  # examples are non-executable until policy approved
  host:
    vmRoot: 'C:\Sentinel\Level1-Sandbox\VMs'
    imageCache: 'C:\Sentinel\ImageCache'
    wslDistribution: Ubuntu-26.04
  image:
    distribution: Ubuntu
    architecture: amd64
    buildId: '20261016'
    sourceUrl: https://cloud-images.ubuntu.com/releases/26.04/release-20261016/ubuntu-26.04-server-cloudimg-amd64.img
    expectedSha256: null   # MUST be a previously approved 64-hex digest before apply
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
  secretRefs: {}  # reserve references only, never resolved values
```

## Strict validation

- Reject unknown fields, unrecognized `apiVersion`, and unsupported provider/mode.
- Require unique VM names, MAC addresses (if supplied), and IPs in one subnet, excluding host IP.
- Enforce isolation from protected VMs, networks, switches, directories and routes. This must derive from validated policy, **not solely the user-editable config**: removing an entry from `protection` must not remove platform protections.
- Require positive bounded CPU/RAM/disk settings; **fixed RAM** by default. A lower startup minimum is prohibited for this lab.
- Require canonical pinned HTTPS image source and an approved digest. The checksum listing's authenticity must be established before accepting its hash.
- Reject path traversal and unapproved VM and image-cache roots.
- Do not resolve secrets during `plan`; no network-based secret fetches in CI; no environment-specific values in a public PR.
- Fail closed on missing public SSH key, missing provider, a conflicting route or an existing target resource.
- Bind `apply` to immutable approved code SHA, config SHA and plan digest so plan and apply cannot silently diverge.
- `verify` must run authentic SSH, hostname, cloud-init, sudo and guest RAM checks, not just TCP port 22.

## Migration note

A normalization layer should transform this YAML into the exact typed PowerShell configuration contract consumed by the existing preflight, image, and infrastructure modules. Do not perform a flag-day change to `Sentinel.Infrastructure.psm1`; add tests and a read-only compatibility mode first.

## Findings from PR #1 (address before merge)

1. `infrastructure/level1/tests/test_package_contract.py` and `Test-StaticSafety.ps1` require `config/lab.json`, which is Git-ignored; tests need synthetic fixtures and an explicit `-ConfigPath` or injected configuration object.
2. `infrastructure/level1/config/stages.json` still marks Stage 2 image and Stage 3 infrastructure tasks unimplemented although the CLI has them.
3. `infrastructure/level1/README.md` claims only preflight is implemented.
4. `Assert-Stage3Specification`, static MAC layout and `Assert-SentinelGuestHealth` enforce one concrete VM pair; this must become **policy-validated configuration**, not a broad removal of safety checks.
5. Current file storage includes cloud-init `user-data`; public keys are fine, but future secret-bearing user-data would need dedicated handling and data-retention controls.

These findings are **not fixes**; no executable provisioning code changes in this proposal.
