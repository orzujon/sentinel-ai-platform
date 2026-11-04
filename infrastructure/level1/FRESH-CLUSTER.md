# Separate two-node Kubernetes bootstrap

**Current live state (operator report, 2026-11-04):** exactly two fresh VMs `cp01` and `w01` were built through one uninterrupted BOOTSTRAP on Git commit `30c7927fbbbd57baef2e0516cf7ba7b210a238f6`, then both successfully recovered after the separately approved sequential reboot test. Final markers: `FRESH_BOOTSTRAP_E2E_PASS` and `FRESH_REBOOT_PERSISTENCE_PASS`. See [clean acceptance](CLEAN-BOOTSTRAP-ACCEPTANCE.md). Historical notes below describe the older `sentinel-fresh-*` experiment and **do not** describe the current VM inventory. The `cp01/w01` cluster is occupied; do not rerun BOOTSTRAP on it.

Status: first operator-run live build completed with in-run code corrections;
network acceptance and post-cleanup verification passed on 3 November 2026.
The original sandbox passed operator-run verification on 2 November 2026
(`20261102T220339Z-caa7d893`). No infrastructure was changed during development.

## Live acceptance record — 3 November 2026

The operator reported both creation plans passing and ran the fresh bootstrap.
The first run required fixes for adapters without `IPAddresses`, the shared
SSH trust helper's disposable-only address scope, and the active-network
test's old Pod CIDR assertion. The first network-test failure cleaned up its
owned diagnostic namespace; the cluster was preserved and only the corrected
network stage was rerun. All live commands were operator-run.

Reported final evidence:
- `FRESH_STAGE_PASS: network-test`, audit
  `/home/orzu/.local/state/sentinel-fresh/network-test-nj_botbx/audit.json`.
- `FRESH_STAGE_PASS: verify`, audit
  `/home/orzu/.local/state/sentinel-fresh/verify-gvh5muex/audit.json`.

This establishes a completed live cluster with active network checks and a
successful post-cleanup verification. Audit paths and success markers were
provided by the operator; audit contents have not been independently read here.
It does not establish an uninterrupted BOOTSTRAP run, full apply idempotence,
repeatable rebuilds, or restoration of the powered-off original cluster.

## Fixed new environment

| Role | Name | Private address | Management/private MAC |
| --- | --- | --- | --- |
| Control plane | cp01 | 10.78.0.30 | 02AA78000130 / 02AA78000030 |
| Worker | w01 | 10.78.0.31 | 02AA78000131 / 02AA78000031 |

Both guests: 4 GiB static RAM, 2 vCPUs, 60 GiB dynamic VHDX capacity.
Storage: `C:\Sentinel\FreshCluster\VMs\<name>`. Existing switches:
`Default Switch` (management DHCP) and `Sentinel-L1` (private NIC, named
`sentinel0` inside each guest). No host switch or network changes.
Pod CIDR: `10.245.0.0/16`. Service CIDR: `10.112.0.0/16`.
These are new profile choices; operator review and live conflict checks remain
required. Absence from a neighbour cache cannot prove an address is unused.

All other VMs are outside this profile, including both historical clusters,
regression VMs and the successful `sentinel-e2e-auto20` test VM. Creation refuses
occupied new names/paths, shared IP/MAC observations and unverified peer identity.
There is no deletion/reset/rollback mode in this workflow.

Host observation at 22:14 UTC: 6.81 GiB available RAM, 8 GiB assigned to the
existing sandbox pair, 2 GiB assigned to auto20, and 1495.73 GiB disk free.
Capacity policy: remaining guests plus 6 GiB available host RAM reserve;
remaining full disk capacities plus 20 GiB disk reserve. Recheck after shutdown;
assigned RAM is not a guaranteed future free-memory value. Configured vCPUs
are not treated as exclusive physical CPU reservations.

## Reuse and isolation

- `New-SentinelFreshVM.ps1` and `Invoke-SentinelFreshTrust.ps1` are deliberately
  separate, scoped derivatives of Stage54 entrypoints. They reuse the disk/seed
  helper, firstboot setup, KVP parser, trust-store and WSL path modules. Stage54
  creation/cleanup entrypoints and their single-disposable guard are unchanged.
- Guest seed schema 3 permits only this new pair; schema 2 retains only the
  disposable range. Host KVP validation accepts the new pair only when the
  separate caller explicitly selects `-FreshCluster`. UUID, nonce, MAC/IP,
  disk/config path and fresh SSH host key must agree before trust registration.
- Existing private SSH keys remain in Windows/WSL. Public login keys must match
  before creation. Cloud-init installs the Ubuntu TLS/GPG/Python APT prerequisites
  used by the existing baseline playbooks, alongside firstboot KVP tools.
- `fresh_cluster.py` builds a private WSL inventory solely from both newly
  verified manifests and dedicated trust files. It never loads an old inventory.
  Each invocation checks both identities through Hyper-V, then checks each
  guest's seed nonce and hostname before the selected Ansible stage.
- Existing baseline, signed repository, package, init, Flannel, join and
  validation playbooks are reused. Only private copies of init/CNI playbooks
  receive new CIDR literals. Existing playbooks and old reconcilers are unchanged.
- Flannel v0.28.10 upstream bytes must match an independently reviewed SHA256.
  Rendering sets the new Pod CIDR and binds VXLAN to `sentinel0`. The distinct
  rendered digest is recorded and used for deployment verification; it is never
  described as the upstream digest.
- Kubernetes/containerd versions remain those pinned in the existing playbooks.
  Missing/changed APT candidates block; this code does not silently upgrade pins.

## Operator workflow (Administrator Windows PowerShell 5.1)

Use the isolated development clone while reviewing this change:

```powershell
$tools = 'C:\Sentinel\fresh-cluster-development\infrastructure\level1\tools'
& "$tools\Get-SentinelFreshClusterPlan.ps1"
```

The capacity collector is non-mutating and prints JSON. Its `CreateSupported`
field describes the collector, not the separate execution entrypoint.
`Invoke-SentinelFreshCluster.ps1 -Stage PLAN` adds strict current host/collision
checks. It will block on the currently observed RAM shortage. It does not yet
validate the image, APT availability, package candidates or guest state.

After code review and offline CI, gracefully stop the existing Level1 pair
with the separate `Invoke-SentinelSandboxPower.ps1` helper. Supply its UUIDs
from independently reviewed inventory, not a name lookup that silently accepts
a replacement VM. First use PLAN; STOP requires
`STOP_EXACT_SENTINEL_SANDBOX_PAIR`. The helper requests worker shutdown before
control-plane shutdown and never forces power-off. It preserves disks and
configuration. START requires `START_EXACT_SENTINEL_SANDBOX_PAIR` and starts
control plane before worker; run the original bootstrap-verify afterward.
Do not restart the old pair while the new pair consumes the available RAM.

Before creation, collect capacity again and review addresses, image pin and
Flannel upstream digest. The one-command clean build is:

```powershell
# Set these to the independently reviewed Stage2 artifact and upstream digest.
# Do not substitute a freshly downloaded digest and call it reviewed.
& "$tools\Invoke-SentinelFreshCluster.ps1" -Stage BOOTSTRAP `
  -ImagePath $reviewedImagePath -ImageSHA256 $reviewedImageSHA256 `
  -FlannelSHA256 $reviewedFlannelSHA256 -Approval FRESH_BOOTSTRAP
```

BOOTSTRAP checks both creation plans before creating either VM. It executes
CREATE -> bounded KVP wait -> TRUST for each node, followed by READINESS,
BASELINE, REPOSITORY, PACKAGES, INIT, CNI, JOIN, VERIFY and NETWORK-TEST.
`FRESH_BOOTSTRAP_E2E_PASS` is printed only after all stages actually succeed.
NETWORK-TEST creates temporary diagnostic Pods/Service and removes only its
owned diagnostic namespace using the existing safety checks.

Individual steps are available for review and diagnosed continuation:

| Stage | Required approval |
| --- | --- |
| PLAN, READINESS, VERIFY | none |
| CREATE -Node control-plane | FRESH_CREATE_CONTROL_PLANE |
| CREATE -Node worker | FRESH_CREATE_WORKER |
| TRUST -Node control-plane | FRESH_TRUST_CONTROL_PLANE |
| TRUST -Node worker | FRESH_TRUST_WORKER |
| BASELINE / REPOSITORY / PACKAGES / INIT / CNI / JOIN | FRESH_<STAGE> |
| NETWORK-TEST | FRESH_NETWORK_TEST |

CREATE also needs the image path/hash. CNI also needs the reviewed upstream
Flannel hash. All mutation approvals are checked before Hyper-V/WSL access.

## Follow-up: configuration-driven artifact selection

Operator request, 3 November 2026: do not require copying the Ubuntu image
path and SHA256 into every command. This is a future CLI improvement, not
implemented in the current entrypoints.

- Resolve a named environment/profile to a reviewed, version-controlled image
  catalog entry containing the exact build, source and SHA256; derive its local
  cache path from that entry.
- Load the reviewed Flannel version and upstream SHA256 from its release lock
  as well, rather than requiring another copied checksum argument.
- Keep artifact verification mandatory on use. Never silently select the
  latest image, trust a checksum calculated from an unapproved file, or replace
  a reviewed pin after a mismatch.
- PLAN should display resolved versions, pins and configuration revision for
  review. Missing/unapproved entries and mismatches must block before creation.
- Acceptance: normal PLAN/BOOTSTRAP commands need only a profile and the
  applicable execution approval, with no repeated paths or checksums. Retain
  explicit overrides only as a separately reviewed advanced workflow.

## Failure and rerun semantics

BOOTSTRAP is a clean build, not an automatic resume engine. A failed run leaves
its VMs/disks and private audit intact and refuses a second creation pass.
KVP waiting never falls back to trusting network-first SSH.
The wait output reports elapsed time, attempt number and the last host-side
verification error, immediately when the error changes and every six attempts
otherwise. This is verification telemetry, not a stream of guest APT/cloud-init
logs. An already running controller does not pick up edits to its loaded loop.
To expose its current verification failure without restarting, run the separate
`Invoke-SentinelFreshTrust.ps1 -Mode VERIFY -Node control-plane` from another
Administrator PowerShell window. This does not register trust or log into SSH.
Guest firstboot logs remain in `/var/log/cloud-init-output.log` and the KVP
setup status in `/var/lib/sentinel/firstboot-kvp.status`; they are not currently
exported to the Windows controller before trust. A future console/serial
logging channel must avoid a dependency on the KVP service being debugged.

First-install repository/package/init playbooks intentionally reject existing or mixed state.
Do not blindly retry a failed stage or bypass its checks; inspect its audit and
actual guest state before selecting a continuation. There is no automatic data
cleanup, rollback, VM deletion or kubeadm reset.

VERIFY is the supported read-only rerun once the cluster is built. It verifies
exact Ready node identities, versions, CoreDNS and Flannel. NETWORK-TEST is a
separately approved active DNS/cross-node/Service check. Full apply idempotence,
a repeated fresh rebuild and live failure recovery are NOT yet demonstrated.
KVP remains host/seed-based trust, not cryptographic guest integrity attestation.

## Offline checks and remaining acceptance

- PowerShell: Test-FreshClusterPlan, Test-FreshCluster, Test-FreshClusterHost,
  Test-SandboxPower, existing Test-Stage54 and Test-KvpEvidence.
- Python: `test_fresh_cluster.py`, existing `test_firstboot_kvp.py` (Linux pool
  and Bash fixture tests are skipped on Windows).
- Linux CI: `python infrastructure/ansible/tests/check_fresh_syntax.py` checks
  the actual rendered playbooks and new identity guard with Ansible syntax-check;
  it does not connect to any guest.
- Local Windows YAML parsing is not equivalent to the Linux Ansible syntax gate.
- Host plan, active network acceptance and post-cleanup VERIFY passed in the
  operator-run session above. Still required: CI on the final reviewed revision,
  an uninterrupted clean build and a separately approved repeatability/rebuild test.

Private per-stage evidence lives below `/home/<user>/.local/state/sentinel-fresh`.
Join credentials remain in the existing playbook's no_log in-memory tasks.
