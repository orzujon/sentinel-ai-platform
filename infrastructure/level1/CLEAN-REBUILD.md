# Fresh cluster clean-bootstrap acceptance

Purpose: retire ONLY the current fresh pair and the Stage54 auto20
disposable, then rebuild the fresh pair **using the same names and IPs**.
This PR does not run any Hyper-V operation. No source-code approval or merge
automatically authorises destruction. Deleting the guest disks permanently
discards the current fresh cluster's Kubernetes data.

## Inventory and scope

Historical inventory: 9 VMs (four pairs plus one disposable). This is
NOT a fresh observation. In Administrator Windows PowerShell:

```powershell
Get-VM | Sort-Object Name | Select-Object Name,State,Id,MemoryAssigned
```

Exact requested targets:

- `sentinel-fresh-cp01` (10.78.0.30): use its LIVE UUID, independently
  cross-check against its provisioning manifest
- `sentinel-fresh-w01` (10.78.0.31): use its LIVE UUID, independently
  cross-check against its provisioning manifest
- `sentinel-e2e-auto20` (10.78.0.20): previously reported UUID
  `acb38617-06a6-48d7-a805-a48dab8e9dc3`. Recheck it live.

Historical `k8s-*`, `sentinel-l1-*`, regression VMs, switches, Stage2
Ubuntu cache, private SSH keys and unrelated directories are OUT OF SCOPE.

## Read-only preflight

Only after checking out the PR, with a clean working tree and passing CI:

```powershell
$tools = '.\infrastructure\level1\tools'
$ids = @{
  ExpectedControlPlaneVMId = [guid]'PUT-ACTUAL-CONTROL-PLANE-UUID-HERE'
  ExpectedWorkerVMId = [guid]'PUT-ACTUAL-WORKER-UUID-HERE'
}
& "$tools\Remove-SentinelFreshCluster.ps1" -Mode PLAN @ids
& "$tools\Remove-SentinelStage54Disposable.ps1" -Mode PLAN -Target stage54 -Slot 20 -ExpectedVMId ([guid]'acb38617-06a6-48d7-a805-a48dab8e9dc3')
```

Expected markers: `FRESH_REMOVE_PLAN_READY` and
`STAGE54_CLEANUP_PLAN_READY`. Inspect each target and UUID. Any BLOCKED
result requires diagnosis, not bypass. The scripts check exact VM+manifest
identity, disks, checkpoints, parent VHDs, NIC/MACs and foreign ownership.

## Irreversible removal — distinct, explicit operator approval

Only after inspecting both PASS plans and approving data loss:

```powershell
& "$tools\Remove-SentinelFreshCluster.ps1" -Mode REMOVE @ids -Approval REMOVE_EXACT_SENTINEL_FRESH_PAIR_FOR_REBUILD
& "$tools\Remove-SentinelStage54Disposable.ps1" -Mode REMOVE -Target stage54 -Slot 20 -ExpectedVMId ([guid]'acb38617-06a6-48d7-a805-a48dab8e9dc3') -Approval REMOVE_EXACT_SENTINEL_STAGE54_DISPOSABLE
```

The fresh-pair remover uses a non-forced guest shutdown, worker before
control plane, and rechecks BOTH are Off before unregistering either. Then
it deletes only each exact verified VM-owned folder. The E2E remover is the
existing audited Stage54 tool. No rollback is guaranteed: if a removal
partially fails, inspect and preserve remaining resources.

Confirm absence without modifying anything:

```powershell
Get-VM | Sort-Object Name | Select-Object Name,State,Id
Get-ChildItem C:\Sentinel\FreshCluster\VMs -ErrorAction SilentlyContinue | Select-Object Name
```

## Next: one uninterrupted bootstrap, then persistence

Rebuild ONLY the same fresh CP/W01 identities and IP allocations.
Require empty VM names/paths, available RAM/disk, no IP/MAC conflict and a
clean bootstrap PLAN. Fixed, previously checked artifact hashes remain
required. Do not run BOOTSTRAP until teardown and preflight pass.

Acceptance is one complete unchanged-code execution: CREATE -> KVP ->
strict SSH -> Ansible -> containerd -> Kubernetes -> Flannel -> JOIN ->
VERIFY -> NETWORK-TEST. Record immutable code revision, artifact hashes
and every stage result. Then deliberately reboot the newly created nodes,
verify both Ready, API/DNS/Flannel and cross-node+Service traffic again.
This must be separately planned and explicitly approved.

Formal artifact approval work is parked as a future TODO. Keep existing
SHA256 integrity controls; never invent an approval or change a hash simply
because a file differs. No live Kubernetes operation is triggered by this PR.
