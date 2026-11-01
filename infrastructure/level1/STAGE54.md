# Stage 5.4 — Fresh VM → Hyper-V KVP → trusted SSH → Ansible

**Status (1 November 2026):** Implemented in `feature/stage54-zero-to-ansible` and CI-tested using synthetic guest KVP pools and Windows offline tests. **A new Stage 5.4 VM has not yet been created or tested live.** The previous `sentinel-e2e-w02` live KVP/SSH pass remains the evidence for the underlying identity flow.

The Stage 5.4 provisioner **never touches** `sentinel-l1-cp01`, `sentinel-l1-w01`, `k8s-cp01`, `k8s-w01`, `sentinel-e2e-w02` or any existing switch. It only creates a fresh, nonexisting `sentinel-e2e-auto20` through `sentinel-e2e-auto29` with a reviewed Ubuntu 26.04 cloud image, two matching-MAC Hyper-V NICs and a new UUID/nonce. It does not install Kubernetes.

## Critical architectural change

Stage 5.3 used a *provisional* SSH connection to install the guest publisher, then Hyper-V KVP to verify that VM's SSH host identity. This was useful proof but still included an initial network first-contact dependency.

Stage 5.4 **bakes the publisher and per-VM manifest into the trusted cloud-init seed ISO before first boot**, then attempts to install signed Ubuntu kernel-matched KVP packages and publish the freshly generated **SSH host public key**. Windows reads the key from the exact Hyper-V VM through `Msvm_KvpExchangeComponent.GuestExchangeItems`, checks its VM UUID and nonce against the independent Windows manifest, verifies the candidate network SSH public key, and only then registers a protected dedicated `trusted_known_hosts` entry. SSH authentication and the Ansible `ping` module both use pinned host-key checking; no `accept-new` or global known_hosts mutation.

The guest KVP daemon and Ubuntu package repositories must work. **If Default Switch DNS fails as observed in the earlier disposable lab, first-boot package installation can fail; this is a BLOCKED state, not a reason to fall back to accepting an unknown host key.** Debug via the Hyper-V VM console and cloud-init logs.

## Supported test scope

- Slots: 20–29 only. Default slot: 20.
- Names: `sentinel-e2e-auto20` ... `sentinel-e2e-auto29`.
- Private static IP: `10.78.0.20` ... `10.78.0.29`, each exactly matching its slot.
- NICs: existing `Default Switch` DHCP management, existing `Sentinel-L1` private IP/MAC. No new switches.
- 2 GiB static startup RAM, 2 virtual CPUs, 24 GiB VHDX.
- Protected artifacts: `C:\Sentinel\Stage54\sentinel-e2e-auto20\` and equivalents.
- No automatic VM destruction, adoption, rollback, reboot, key replacement, trust-on-first-use or global SSH configuration changes.
- Fresh source image *and* matching SHA256 and cache-side Stage 2 metadata required.
- Ansible requires the pre-existing WSL Ubuntu-26.04 installation, `ansible` command, and an existing WSL login key at `/home/orzu/.ssh/id_ed25519`. This pipeline doesn't generate or copy user private keys.

## Start safely — read-only PLAN

In **Administrator PowerShell**, using the Stage 2 image that was reviewed earlier:

```powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform
git fetch origin
git switch feature/stage54-zero-to-ansible
git pull --ff-only origin feature/stage54-zero-to-ansible

$imagePath = 'C:\Sentinel\ImageCache\ubuntu\26.04\20261016\5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5.img'
$digest = '5645d0318ad21f643ebb1ac4567514620e9893380b07b0201fda163baa5b7eb5'

.\infrastructure\level1\tools\Invoke-SentinelStage54.ps1 -Mode PLAN -Slot 20 -ImagePath $imagePath -ImageSHA256 $digest
```

Expect `STAGE54_CREATE_PLAN_READY` followed by `STAGE54_ORCHESTRATOR_PLAN_READY`. PLAN does not create disks or VMs, modify host keys, or connect with SSH. The CLI refuses occupied names, folders, addresses observed on the host, MAC collisions, missing switches, inadequate RAM, unreviewed images and missing guest scripts. A neighbour-cache absence alone does **not** establish that an IP is universally free.

## One-command approved RUN (only after PLAN review)

```powershell
.\infrastructure\level1\tools\Invoke-SentinelStage54.ps1 -Mode RUN -Slot 20 -ImagePath $imagePath -ImageSHA256 $digest -WSLPrivateKey '/home/orzu/.ssh/id_ed25519' -Approval CREATE_AND_REGISTER_FRESH_SENTINEL_STAGE54
```

RUN executes: fresh-VM CREATE → guest first-boot KVP publication → Hyper-V KVP/VM UUID/nonce/network host-key verification → protected trust registration → pinned Windows SSH `hostname` → pinned WSL Ansible `ping`.

Expected terminal marker **only on actual live success**: `STAGE54_ZERO_TOUCH_E2E_PASS`.

Firstboot fails closed, and RUN times out rather than automatically accepting an unknown host key or deleting the new VM. **Do not retry RUN/CREATE against a partially created VM.**

## Controlled recovery / individual stages

When a new VM exists, use the following for **read-only** identity inspection or separately approved recovery after first-boot issues are corrected through the console:

```powershell
.\infrastructure\level1\tools\Invoke-SentinelStage54Trust.ps1 -Mode VERIFY -Slot 20
.\infrastructure\level1\tools\Invoke-SentinelStage54Trust.ps1 -Mode REGISTER -Slot 20 -Approval REGISTER_KVP_VERIFIED_SENTINEL_STAGE54_HOST_KEY
.\infrastructure\level1\tools\Invoke-SentinelStage54Trust.ps1 -Mode ACCEPT -Slot 20
.\infrastructure\level1\tools\Invoke-SentinelStage54Trust.ps1 -Mode ANSIBLE -Slot 20 -WSLPrivateKey '/home/orzu/.ssh/id_ed25519'
```

The `REGISTER` step creates **only** the protected dedicated `trusted_known_hosts` file. The `ANSIBLE` step creates a one-target inventory *outside the Git repository*. No secrets or SSH private keys go to Git. Each step revalidates VM UUID, IP/MAC mapping, nonce and observed host key against the guest KVP record.

**Security limitations:** VM/host/seed ownership is the basis of trust; Hyper-V guest KVP is not cryptographic proof of guest integrity. This is an isolated lab bootstrap, not a multi-tenant secure attestation mechanism. The root seed contains a nonce used for correlation, **not** a secret login credential. Guest clock, signed image provenance, firstboot APT trust and Windows host integrity still matter.

**Early key-consistency gate:** before creating a VM, the PLAN/RUN controller verifies that the existing WSL Ansible private key derives the same ED25519 **login public key** injected into cloud-init from Windows. This prevents creating a VM that Windows SSH can access but Ansible cannot. Private key material stays on its original system; only a derived public key is compared. An encrypted WSL private key that cannot be checked noninteractively blocks the plan.


## Mandatory cleanup before creating another disposable VM

Stage54 PLAN and RUN now block while any prior disposable lab VM remains: 
`sentinel-e2e-w02`, `sentinel-e2e-ssh01` or any `sentinel-e2e-auto20..29`.
The preflight also refuses stale disposable storage directories. **No VM or
disk is automatically removed.** Use a separately approved PLAN/REMOVE.

Inventory old lab VMs (read-only):

```powershell
Get-VM | Where-Object { $_.Name -match '^sentinel-e2e-' } | Select-Object Name,Id,State
```

Previously verified **w02**, VM UUID `7ce061eb-ac7a-43d6-bddb-a22070d2c6f9`:

```powershell
# Read-only: prove exact UUID, VHDX, ISO, NICs and exclusive folder ownership.
.\infrastructure\level1\tools\Remove-SentinelStage54Disposable.ps1 -Mode PLAN -Target w02 -ExpectedVMId '7ce061eb-ac7a-43d6-bddb-a22070d2c6f9'

# DESTRUCTIVE: only after reading and approving PLAN's precise deletion report.
.\infrastructure\level1\tools\Remove-SentinelStage54Disposable.ps1 -Mode REMOVE -Target w02 -ExpectedVMId '7ce061eb-ac7a-43d6-bddb-a22070d2c6f9' -Approval REMOVE_EXACT_SENTINEL_E2E_W02
```

Cleanup targets the requested VM and its own files only; it refuses a wrong
VM UUID, any checkpoints, AVHDX/differencing disks, symlinks, unexpected
attachments, or foreign VMs referencing the folder. Running guests are
asked to shut down gracefully; failure blocks rather than forcing power-off.
Neither the existing Kubernetes VMs, Hyper-V switches, nor Stage 2 cache
are modified. Remove only after reviewing the exact UUID and path.

To clean a previously created Stage54 slot, supply its actual UUID from
`Get-VM` and the slot. Example for slot 20:

```powershell
$vmId = (Get-VM -Name 'sentinel-e2e-auto20').Id
.\infrastructure\level1\tools\Remove-SentinelStage54Disposable.ps1 -Mode PLAN -Target stage54 -Slot 20 -ExpectedVMId $vmId
# Destructive; only after confirming PLAN:
.\infrastructure\level1\tools\Remove-SentinelStage54Disposable.ps1 -Mode REMOVE -Target stage54 -Slot 20 -ExpectedVMId $vmId -Approval REMOVE_EXACT_SENTINEL_STAGE54_DISPOSABLE
```

Legacy `sentinel-e2e-ssh01` has its own exact-UUID
`Remove-SentinelDisposableE2E.ps1` cleanup tool. If the VM was already
unregistered but files remain, Stage54's guarded cleanup refuses to infer
ownership and will not delete orphaned data automatically.

## WSL SSH login-key preflight correction

OpenSSH `ssh-keygen -y` supports `-f` but not `-P`. The corrected key
comparison uses a bounded, noninteractive WSL command:

```powershell
wsl.exe -d Ubuntu-26.04 --exec timeout 8s ssh-keygen -y -f /home/orzu/.ssh/id_ed25519
```

It checks that the WSL Ansible private key derives the same ED25519 public
login key cloud-init authorises. No private key is copied. A mismatch blocks
the plan before a VM can be created.


### w02 cleanup: UUID-named Hyper-V runtime directory

During a live read-only PLAN, Hyper-V's nested configuration path
`C:\Sentinel\E2E-WorkerReplica\sentinel-e2e-w02\sentinel-e2e-w02\Virtual Machines`
contained the original VM's `.vmcx`, `.vmgs`, `.vmrs` and an additional
`7CE061EB-AC7A-43D6-BDDB-A22070D2C6F9` directory. This is a legitimate
configuration layout candidate, but filename similarity alone is insufficient
to approve deletion.

`Sentinel.HyperVDisposableLayout.psm1` now permits the UUID runtime directory
only when the actual Hyper-V VM.Path is inside the same named VM folder,
the independent provisioner VM UUID agrees with the live VM, exactly one
matching `.vmcx` exists, all configuration file names are from the exact VM
UUID, and the optional runtime folder is empty or contains only UUID-named
`.bin`/`.vsv` files. Unknown entries remain BLOCKED and are reported with
their precise paths; symbolic links, checkpoint files, differencing disks,
foreign VM attachments, extra configuration entries and changed VHD/ISO
bindings still fail closed.

CI exercises positive and negative cases with temporary filesystem fixtures;
it does **not** run REMOVE against the live Hyper-V host. Retry PLAN and
confirm `CLEANUP_VM_UUID_RUNTIME_VERIFIED`,
`CLEANUP_VM_CONFIG_FILES_VERIFIED` and `STAGE54_CLEANUP_PLAN_READY` before
using any separately approved destructive cleanup command.
