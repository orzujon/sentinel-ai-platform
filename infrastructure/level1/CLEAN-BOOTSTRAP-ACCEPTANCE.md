# Sentinel Level 1 — clean cluster acceptance (cp01 + w01)

**State:** operator-reported clean bootstrap **PASS**, reboot persistence **PASS** on 2026-11-04. Previous VMs were retired; current cluster contains `cp01` and `w01`. Acceptance is based on terminal output supplied by the operator; private audit JSON files have not been independently inspected.

## Target — exactly two new Ubuntu guests

| Role | VM/guest hostname | Private IP | vCPU | RAM | VHDX capacity |
|---|---|---|---:|---:|---:|
| Kubernetes control plane | `cp01` | `10.78.0.30` | 2 | 4 GiB | 60 GiB |
| Worker | `w01` | `10.78.0.31` | 2 | 4 GiB | 60 GiB |

Only the registered VMs are being rebuilt; the `Default Switch`,
`Sentinel-L1` internal switch, private NIC `sentinel0`, Pod CIDR
`10.245.0.0/16`, Service CIDR `10.112.0.0/16`, cached Ubuntu image and
existing controller SSH keys are reused as-is. The guest and VM **names**
are exactly `cp01` and `w01`, not prefixed with Sentinel.

The source code pins its exact target hostname/IP/MAC pairs through Hyper-V,
cloud-init, KVP public-key publication, UUID/nonce binding, strict SSH,
Ansible inventory and Kubernetes acceptance. Unknown other guest VMs, old
names/VM slots and nonempty existing target paths block a clean run. Nothing
automatically cleans up a failed or partial build.

## Step 1 — read-only host inspection

Use Administrator Windows PowerShell **after pulling and checking out this
branch**. Verify the new branch is reviewed and GitHub CI is green before
approving creation.

```powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform
git status --short
git rev-parse HEAD
Get-VM | Select-Object Name,State,Id
.\infrastructure\level1\tools\Invoke-SentinelFreshCluster.ps1 -Stage PLAN
```

Success marker: `FRESH_HOST_PLAN_PASS`. The entrypoint refuses to certify
a clean bootstrap if **any** old VM remains registered. The existing empty,
properly ACL-protected `FreshCluster` parent is allowed; unexpected files,
links or occupied guest folders are not.

A lack of VMs is not itself enough. RAM/disk headroom, switch configuration,
routes, proposed addresses and cached image integrity must also pass.

## Step 2 — the first *uninterrupted* clean BOOTSTRAP

Use the known, SHA256-verified local image, without changing the hash to make
the test pass. The exact known pins are:

- Ubuntu build 20261016 SHA256:
  `5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5`
- Flannel v0.28.10 upstream SHA256:
  `393bdbce53eb50c8eb97dd513b218518b7d6e7985dc7b889be956e112a711084`

The following is **not a read-only command**. Do not run it before a passing
PLAN and an explicit separate operator decision.

```powershell
$bootstrap = @{
    Stage = 'BOOTSTRAP'
    Approval = 'FRESH_BOOTSTRAP'
    ImagePath = 'C:\Sentinel\ImageCache\ubuntu\26.04\20261016\5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5.img'
    ImageSHA256 = '5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5'
    FlannelSHA256 = '393bdbce53eb50c8eb97dd513b218518b7d6e7985dc7b889be956e112a711084'
}
.\infrastructure\level1\tools\Invoke-SentinelFreshCluster.ps1 @bootstrap
```

The script verifies zero pre-existing registered guests, refuses uncommitted
repository changes, prints the exact Git SHA, checks image source and cache
SHA256, then creates both VMs and waits for validated KVP public host keys.
Subsequent stages include trust registration, Ansible readiness, baseline,
package repository, Kubernetes control plane, Flannel, join, VERIFY and active
cross-node/Service network tests. The script must complete without code edits,
manual guest fixes or stage-specific reruns for this acceptance attempt to
qualify. Target signal: `FRESH_BOOTSTRAP_E2E_PASS`.

A failure must preserve the partial build for diagnosis. Do **not** simply
rerun `BOOTSTRAP` on occupied names or delete partial disks manually.

## Step 3 — separately approved full guest reboot and recovery

Only after a successful clean BOOTSTRAP, and after reviewing the health
of both VMs, the disruptive test is:

```powershell
.\infrastructure\level1\tools\Invoke-SentinelFreshCluster.ps1 -Stage REBOOT-TEST -Approval FRESH_REBOOT_TEST
```

This performs an observational Kubernetes VERIFY **first**. Then Ansible
checks exact guest hostname and kubelet/containerd, reboots `w01` followed
by `cp01` (one at a time) over strict KVP-pinned SSH, and checks the
services have restarted and remain enabled. Finally it runs VERIFY again,
then the already scoped active network test (temporary namespace, cross-node
Pod and ClusterIP connectivity). No forced VM power-off or shell-generated
deletion is part of this workflow.

Target: `FRESH_REBOOT_PERSISTENCE_PASS` **only after** health and
network tests pass. The last network test creates/cleans its own temporary
diagnostic resources and is included in the explicit reboot acceptance.
If a reboot stalls, never issue a blind second reboot or force restart.
Inspect Hyper-V and private Ansible audit before recovery.

Each Ansible stage writes its own private audit under the existing
`~/.local/state/sentinel-fresh/` directory in WSL, and the bootstrap logs
its source Git SHA. Aggregate immutable acceptance bundles and independent
artifact promotion remain **future TODOs**; the already tested SHA256
integrity checks stay mandatory.

## Acceptance decision

Success requires one unchanged source revision and verified image/network
hashes, exactly two new VMs, both Ready, working Kubernetes control plane,
CNI/CoreDNS, cross-node/Service tests, a graceful ordered reboot of both
VM guests, and post-reboot health/network verification. This acceptance has been **reported successful from the live cluster**, not inferred from CI. See evidence below. Reproducibility, failure-injection self-healing, and independent artifact provenance acceptance are **not** established by these tests.


## Operator-reported live evidence — 2026-11-04

- Clean BOOTSTRAP completed on the unchanged source revision `30c7927fbbbd57baef2e0516cf7ba7b210a238f6`. The terminal emitted `FRESH_STAGE_PASS: network-test` and `FRESH_BOOTSTRAP_E2E_PASS`. Original network audit: `/home/orzu/.local/state/sentinel-fresh/network-test-v74tj2k7/audit.json`.
- The initial reboot validation failed safely on a stage allowlist, before rebooting; the next run rebooted `w01` and observed `kubelet` still `activating`. Both gaps were corrected with regression tests. These failures do **not** count as successful reboot tests.
- The final approved `REBOOT-TEST` emitted `FRESH_STAGE_PASS: network-test` and `FRESH_REBOOT_PERSISTENCE_PASS` after sequential guest reboots, post-reboot VERIFY and active network checks. Final reported network audit: `/home/orzu/.local/state/sentinel-fresh/network-test-m6asfzne/audit.json`.
- The operator independently inspected `sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide` and `get pods -A`: `cp01` and `w01` both `Ready`, Kubernetes `v1.37.2`, containerd `v2.2.2`, Flannel two Running Pods, CoreDNS two Running Pods and control-plane static Pods Running.
- Windows `kubectl` initially targeted the retired `10.77.0.10` address. Operator reports corrected kubeconfig access to `10.78.0.30`. Windows credential distribution is **not** part of this cluster-bootstrap acceptance and should be hardened to least privilege for application workflows.

The first BOOTSTRAP evidence pins the source commit that actually ran; this later documentation and reboot-guard revision is not represented as the clean-build source. Do not replay BOOTSTRAP against the occupied VMs. Distinct audit JSON contents and long-term recovery trends still need independent validation.
