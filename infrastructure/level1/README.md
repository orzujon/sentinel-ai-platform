> **Stage 5 update (2026-10-31):** A non-mutating `bootstrap-plan` route classifier has been introduced. Stages 1–4 were separately implemented and successfully exercised in the lab; full clean-room orchestration is **not yet implemented**. Stage 4 Kubernetes playbooks and live acceptance evidence are documented under `infrastructure/ansible/`.

> This public README uses fictional example inventory. Run actual infrastructure operations only with separately approved private configuration and validated resource safeguards. The currently imported legacy PowerShell modules still contain environment-specific constants and are being reviewed for extraction.

# Sentinel — Level 1 Infrastructure Provisioning Pipeline

**Status:** Stages 1–3 (preflight, approved image cache, isolated Hyper-V VM provisioning and authenticated guest health) implemented and previously exercised in the local lab. Stage 4 Kubernetes deployment and operational acceptance have been implemented separately and exercised against the dedicated two-node sandbox. Unified clean-room bootstrap is still pending. The repository import has not yet been end-to-end revalidated from this new path.

This includes read-only checks and separately approved provisioning toward an automated Hyper-V → Ubuntu → Ansible → kubeadm → Flannel → Kubernetes provisioning pipeline. It uses a new, isolated sandbox namespace and **never touches your existing** `example-existing-cp`, `example-existing-worker`, `Example-Existing` switch or `198.51.100.0/24` private network.

## Files

```text
infrastructure/level1/
├── sentinel.ps1                  # Windows PowerShell entry point
├── config/
│   ├── lab.json                  # Local, Git-ignored runtime configuration; never commit
│   └── stages.json               # Stage DAG and implementation flags
├── src/
│   ├── Sentinel.Preflight.psm1   # Read-only checks + JSON/JSONL reporting
│   ├── Sentinel.Images.psm1      # Signed-source digest pinning and image cache
│   ├── Sentinel.Infrastructure.psm1 # Hyper-V plan/apply/verify
│   └── Sentinel.GuestHealth.psm1 # SSH and cloud-init quality gate
├── docs/
│   └── ARCHITECTURE.md
├── tests/
│   └── Test-StaticSafety.ps1     # Script parsing, configuration and isolation checks
└── runs/                         # Host-side run evidence (Git-ignored)
```

## Run Level 1 from Windows

Use your existing reviewed local runtime directory with an approved local `config/lab.json`. **Windows PowerShell Administrator** is required for Hyper-V operations:

```powershell
cd C:\ExampleLab\Automation
.\tests\Test-StaticSafety.ps1    # offline checks use synthetic test fixture
.\sentinel.ps1 preflight          # READ-ONLY: no VM or network changes
.\sentinel.ps1 runs               # show stored runs
```

If downloaded PowerShell files are blocked by Mark-of-the-Web, inspect them and use `Unblock-File` on the files you trust rather than disabling system-wide policy.

The preflight returns exit code **2** on a blocker and **0** if ready (possibly with warnings). `runs/<UTC-run-id>/preflight.json` is the machine-readable report; `events.jsonl` contains each check with its timestamp. The read-only preflight writes only run evidence; image and provisioning operations intentionally have additional approved destinations.

**What to expect on your current machine:** Windows 11 Pro, Hyper-V and two existing VMs should be observed. Whether preflight passes depends on *current* free RAM, free disk and route conflicts—it is not inferred from historic system specs. Protected existing VMs are never treated as the proposed sandbox targets.

## Lab defaults — safe separation

- Future sandbox VM names: `example-cp`, `example-worker`.
- Future internal switch: `Example-Isolated`.
- Future subnet: `192.0.2.0/24` (host `.1`, nodes `.10`, `.11`).
- VM budgets: 4 GiB startup each, 2 vCPU each, 60 GiB dynamic VHDX capacity each.
- Planned VM storage: `C:\ExampleLab\VMs` (not your existing VM directory).
- Original Kubernetes remains at `198.51.100.0/24` (`example-existing-cp` and `example-existing-worker`).

Real environment configuration must remain outside public Git. Stage 2 requires an explicitly approved, SHA256-pinned Ubuntu image. The future private YAML loader is a separate read-only tool (`infrastructure/config/plan.py`) and does **not** yet connect to `sentinel.ps1`.

## Important scope boundaries

- `sentinel.ps1` supports `preflight`, `runs`, `image-discover`, `prepare-images`, `verify-image`, `infra-plan`, `infra-provision`, and `infra-verify`. It does not implement Ansible, Kubernetes installation, or destructive teardown.
- The current Hyper-V module uses intentionally hardcoded sandbox safety guards; do not weaken them during YAML migration before fresh, isolated regression tests.
- Run reports are on the Windows host under the project folder; avoid sharing full logs from private enterprise machines.
- No full backup or restore solution exists yet; a disposable test environment must never become the only home of important data.
- Read architecture notes before implementing stage 10 or beyond. Provisioning stages require explicit safety controls and human approval before any Windows reboot or destructive change.

## Prerequisites

PowerShell 5.1+ on Windows 11 Professional/Enterprise, elevated for feature/Hyper-V inspection. Image and VM stages require WSL Ubuntu image tooling; Ansible will be introduced later. Requirements are based on Microsoft Hyper-V requirements: https://learn.microsoft.com/virtualization/hyper-v-on-windows/reference/hyper-v-requirements


## Stage 5 — Bootstrap orchestration (first increment)

Run from an elevated Windows PowerShell session using the local Git-ignored
`config/lab.json` already approved for the sandbox:

```powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform\infrastructure\level1
.\sentinel.ps1 bootstrap-plan
.\sentinel.ps1 runs
```

`bootstrap-plan` checks the pinned environment and classifies the current
Hyper-V sandbox as `verify-existing`, `new-sandbox`, or
`blocked-partial`. The route is recorded in `runs/<id>/bootstrap-plan.json`.
It never creates, stops, resets, adopts, or deletes VMs; it does not run
Ansible or kubeadm. On the current two-node sandbox, the expected route is
`verify-existing`, but the planner is not itself a VM integrity or cluster
health verification. Continue using `infra-verify` and Stage 4 `-Reconcile`
for these independent checks until Stage 5 orchestrates them automatically.

This initial increment intentionally **does not support one-command clean
provisioning**. The existing Stage 3 module refuses to adopt existing guests,
and Stage 4 trust establishment and Kubernetes first bootstrap still require
separate guarded steps. Stage 5 will integrate these stages without removing
existing safety gates, and will require a separate accepted clean-environment
exercise before claiming full bootstrap support.


## Stage 5.2 — One-command existing-environment verification

After the Stage 5.1 planner reports `verify-existing`, the next read-only
step is:

```powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform\infrastructure\level1
.\sentinel.ps1 bootstrap-verify -ConfigRepo "C:\Sentinel\config-readonly"
```

This first checks the pinned Hyper-V sandbox switch type and host private IP,
then confirms both VM names, approved storage paths, Running states and both
network adapters. It then invokes the existing Stage 4 read-only `-Reconcile`
entry point, which checks trusted SSH identities, Flannel, worker membership
and cluster health. It never supplies an apply token. A private host-side
`runs/<id>/bootstrap-verify.json` records each successful gate and the final
`VERIFIED` or `BLOCKED` result. The nested Stage 4 controller separately
writes its private reconciliation audit.

The command does **not** create missing VMs, reinstall Kubernetes, reset the
cluster, or recover persistent application data. It is verification of an
existing healthy environment; fresh bootstrap from empty VMs remains a
separate implementation milestone. A live successful `bootstrap-verify` run
is required before calling Stage 5.2 operationally complete.


## Stage 5.3 — Fresh-bootstrap dependency and approval contract

A new `freshBootstrapSteps` array in `bootstrap-plan.json` records the
ordered lifecycle, independent approvals, and currently missing integration.
Run the existing **read-only** planner then inspect the new sequence:

```powershell
.\sentinel.ps1 bootstrap-plan
$latest = Get-ChildItem .\runs -Directory | Sort-Object Name -Descending | Select-Object -First 1
(Get-Content (Join-Path $latest.FullName 'bootstrap-plan.json') -Raw | ConvertFrom-Json).freshBootstrapSteps |
    Format-Table order,id,operation,approval,ready -AutoSize
```

This is an architecture and safety contract, not a provisioning executor. It
records that the existing verified image/Hyper-V/Ansible primitives are
individually implemented, while **first-time SSH host-key attestation** and
**worker enrollment from a never-joined cluster** require separate safe
integration. The current Stage 4 controller protects SSH trust by requiring
previously pinned keys; it deliberately does not auto-trust a new VM's public
key. Similarly, the approved reconciliation workflow is for already created
Kubernetes control planes. It must not be used to claim a fresh-cluster
bootstrap succeeds automatically. `freshBootstrapReady: false` prevents that
misrepresentation. Stage 5.3 will add a separate, properly approved fresh
path with bounded waits, recovery checkpoints, artifact verification and
single-run evidence. Do not remove or reset the functioning sandbox to test it.


### First-boot SSH host-key attestation — offline comparison gate

`infrastructure/ansible/verify_first_boot_hostkey.py` now validates an
independently attested ED25519 guest host public key against an observed
candidate, strictly tied to an expected node/IP pair. **This is comparison
only.** It does not fetch the candidate, create known_hosts entries, or
bootstrap SSH trust; it must not be treated as an automatic first-use trust
implementation.

Inputs (private, operator-controlled paths):

```powershell
python .\infrastructure\ansible\verify_first_boot_hostkey.py `
  --node sentinel-l1-cp01 --address 10.78.0.10 `
  --attested-file C:\PrivateLab\hostkeys\cp-console.pub `
  --observed-file C:\PrivateLab\hostkeys\cp-network.pub
```

Acquire the `attested-file` from the Hyper-V guest console or another
independently verified mechanism—not from the same network endpoint being
verified. Comparing two network-fetched keys proves nothing about server
identity. Only after a valid match and separate reviewed approval should an
integrator write trusted known_hosts records. The **currently running lab
must not have its existing trusted records changed** during this development.


### Stage 5.3 — First-boot trust store registration (new, not yet integrated)

`infrastructure/ansible/register_first_boot_hostkeys.py` now prepares a
**new private dedicated** `firstboot-known_hosts` file for the two newly
provisioned sandbox guests, after comparing both nodes' independently attested
console public keys against observed SSH host keys. It requires explicit
approval, prohibits identical host identities, checks that the private state
directory is restricted, and refuses to replace an existing trust file.

Run only in an approved, fresh disposable environment with already-reviewed
independent console evidence, *not on the running two-node Kubernetes lab*.
The operator must independently authenticate the origin of both console files:
file-path separation alone does not prove independence.

```bash
python3 infrastructure/ansible/register_first_boot_hostkeys.py \\
  --cp-attested /private/console/cp.pub \\
  --cp-observed /private/network/cp.pub \\
  --worker-attested /private/console/worker.pub \\
  --worker-observed /private/network/worker.pub \\
  --private-root /private/sentinel-new-deployment \\
  --approval REGISTER_NEW_SENTINEL_HOST_IDENTITIES \\
  --attestation-reviewed
```

This example requires the target `--private-root` directory to exist with
permissions `0700` and creates only a new `0600` known-hosts file. It does
not automatically acquire independent VM host-key evidence, does not amend
`~/.ssh/known_hosts`, does not perform SSH or Ansible, and is not yet linked
to the full bootstrap orchestrator. Stage 5.3's `guest-first-trust` remains
**ready: false** pending verified secure provisioning-channel collection and
full integration. Never treat two copies of the same network-provided key as
independent attestation.

### Hyper-V Linux guest management channel discovery (read-only)

Microsoft documents Hyper-V **Data Exchange / KVP**, which moves small
guest-provided key/value messages over VMbus independently of the guest IP
network. Linux requires the `hv_kvp_daemon` integration service. Unlike
PowerShell Direct, which requires a **Windows guest**, Hyper-V KVP can work
with Ubuntu guests. This does **not** by itself make guest-published strings
cryptographically authenticated or establish SSH trust. We must bind evidence
to the new provisioned VM ID and verify its lifecycle and trusted origin.

Run the host-only probe **on the existing working VMs**, without changing
their configuration:

```powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform
.\infrastructure\level1\tools\Inspect-SentinelHyperVKvp.ps1
```

The probe checks VM identity, Data Exchange enabled status and presence of
the reserved `Sentinel.SSHHostKey.Ed25519` guest KVP item. No new items
have yet been added to the guests, so `publishedKeyPresent: False` is
expected. A missing KVP service blocks this channel rather than falling
back to unauthenticated SSH. Do **not** set Step 40 `ready: true` yet:
we still need an approved guest evidence publisher and a strong
provisioning-time VM identity/freshness binding, followed by offline
comparison and private trusted-host registration.

Reference: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/integration-services-data-exchange


### Stage 5.3 guest KVP prerequisites — safe read-only discovery

The host-side probe confirmed that both working guests expose Hyper-V Data
Exchange. The next **non-mutating** check is to inspect how Ubuntu exposes
the daemon and Linux KVP pool. Microsoft documents the guest pool 1 under
`/var/lib/hyperv`, while Ubuntu's `hv_kvp_daemon` manpage documents
`/var/opt/hyperv`; Sentinel checks both and refuses ambiguity instead of
writing binary data to an unknown pool.

Copy/inspect `infrastructure/ansible/inspect_guest_hyperv_kvp.py` in your
Linux guest and run `python3 inspect_guest_hyperv_kvp.py`, or invoke the
following from an SSH session already authenticated to an existing VM:

```bash
systemctl is-active hv-kvp-daemon.service || true
systemctl is-active hypervkvpd.service || true
ls -l /var/opt/hyperv/.kvp_pool_1 /var/lib/hyperv/.kvp_pool_1 2>/dev/null || true
ls -l /etc/ssh/ssh_host_ed25519_key.pub
```

The guest-side probe **reads metadata only**. Do not directly append text to
KVP pool files: they contain binary fixed-size records, and careless writes
can damage exchange. A production-ready guest publisher and VM-identity/fresh
challenge protocol remain to be built and tested on a separate disposable VM.
This check leaves Step 40 marked incomplete.

References: <https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/integration-services-data-exchange> and <https://manpages.ubuntu.com/manpages/noble/man8/hv_kvp_daemon.8.html>.


### Stage 5.3 — Pinned Hyper-V KVP daemon package planning

Read-only APT evidence from Ubuntu 26.04 (2026-11-01) shows
`linux-cloud-tools-common` **not installed** and current candidate
`7.0.0-42.42` from `resolute-updates/main`. This package supplies
`hv-kvp-daemon.service` (hyphenated service name, not
`hv_kvp_daemon.service`) and the `hv_kvp_daemon` executable.

`infrastructure/ansible/playbooks/35-hyperv-kvp-package-plan.yml` adds
fresh-only, **read-only** preflight guards for two pinned sandbox Ubuntu
26.04 nodes. Requires controller-injected `sentinel_fresh_bootstrap: true`,
refuses existing Kubernetes markers, inspects installed state, and checks
that the exact APT candidate matches `7.0.0-42.42`. It does **not** update
APT, install packages or change running services. The Stage 5.3 orchestration
still needs an authenticated fresh-VM-only execution path, verified
package/service installation, and host-key KVP publisher. **Do not execute
fresh-only steps on the existing Kubernetes cluster.**


### Stage 5.3 — Approval-gated KVP daemon installation (not yet wired to runner)

`infrastructure/ansible/playbooks/36-hyperv-kvp-package-apply.yml`
now defines a two-phase installer for **new, independently SSH-authenticated**
Ubuntu 26.04 sandbox VMs only. It first checks **both** guests for the exact
inventory, approval flags, Kubernetes state markers and reviewed APT package
revision (`7.0.0-42.42`). Only after both pass does it install the exact
`linux-cloud-tools-common` version **serially**, start and enable
`hv-kvp-daemon.service`, and check the installed version and active service.

The apply playbook requires controller-injected booleans
`sentinel_fresh_bootstrap`, `sentinel_kvp_install_approved`, and
`sentinel_kvp_ssh_identity_verified` all true. These booleans are not proof
of identity by themselves. The current Stage 4 management runner does **not**
expose this new installation mode, because trustworthy first-boot SSH
onboarding has not yet been integrated. No existing VM should be targeted.

Ansible syntax and offline safety tests run in CI. Live install acceptance
requires a separately approved **disposable** fresh Ubuntu environment,
including a verified host identity. This is an explicit prerequisite, not
permission to change the running Sentinel Kubernetes cluster.


### Stage 5.3 — Guest-to-host KVP evidence publisher (NEW; not deployed)

`infrastructure/ansible/publish_guest_kvp_hostkey.py` now implements a
fresh-only, one-shot **guest-side** publisher for the host ED25519 SSH *public*
key. Microsoft documents Linux pool 1 as a guest-to-host binary record store
with 512-byte key and 2048-byte value fields. Unlike writing raw text, this
implementation validates a fixed-size record layout, locks the existing
**daemon-created** pool with POSIX advisory locking, refuses partial records
or an already-published identity and appends one complete record. It does not
open or copy SSH private keys.

It records a 32-byte hex provisioning nonce, node name/IP, SSH public key and
fingerprint in a reserved `Sentinel.SSHHostKey.Ed25519` record. The nonce is
**not** proof by itself; it must be generated by the trusted Hyper-V
provisioner, bound to its specific new VM ID and delivered via an approved
cloud-init seed, then checked independently by the controller. Missing
nonce provenance or stale/reused VM evidence must block trust.

The default CLI mode is read-only validation (`PLAN_ONLY`). A separate
`--apply --approval PUBLISH_FRESH_SENTINEL_KVP_HOSTKEY` invocation must
be restricted to a **new disposable VM** with KVP daemon already running.
This publisher is not added to the Stage 4 reconciler or installed on the
working Kubernetes guests. Never copy/run the approved apply mode on
`sentinel-l1-cp01` or `sentinel-l1-w01` while they host the existing
cluster. The authorisation string is an operator gate, **not** a secret.

**Next mandatory work:** verify actual Ubuntu 26.04 daemon interoperability
against a separate disposable VM, implement VM-ID/nonce-bound host-side
collection, perform network-host-key matching and connect the private
trusted-hosts registrar. Until full live acceptance Step 40 remains
`ready: false`.

Source: <https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/integration-services-data-exchange>.


### Stage 5.3 — First real disposable end-to-end acceptance

We have **not** yet executed the guest publisher against the real Linux KVP
daemon. Synthetic pool tests do not prove daemon interoperability, and direct
pool writes require validation on a disposable guest before promotion.
The current Stage 3 provisioner is pinned to `sentinel-l1-cp01` and
`sentinel-l1-w01`; it must never be used for this acceptance run because
those VM names already host the working cluster.

Start from Windows PowerShell, read-only:

```powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform
git switch feature/stage53-clean-bootstrap
git pull --ff-only origin feature/stage53-clean-bootstrap
.\infrastructure\level1\tools\Test-SentinelDisposableE2E.ps1
```

The checker proposes **one** distinct `sentinel-e2e-ssh01` VM, backed by
`C:\Sentinel\E2E-Disposable`, 3 GiB RAM, 30 GiB disk, attached to the
existing Hyper-V Default Switch. It inspects host resource headroom, refuses
a pre-existing target name or path and does not create, start or modify
any VM. `READY_FOR_REVIEW` is only a capacity/isolation verdict—not
provisioning approval. A later implementation must securely build and identify
a disposable guest, generate and seal its provisioning nonce, install and
validate the KVP daemon, perform an actual KVP publication test, retrieve
host-side evidence, compare the network SSH key and test authentication.
Protect the existing two-node Kubernetes sandbox throughout.


### Disposable E2E provisioner — explicit approval only

`infrastructure/level1/tools/New-SentinelDisposableE2E.ps1` is a separate,
**one-VM-only**, non-destructive creation workflow for
`sentinel-e2e-ssh01`. The default `-Mode PLAN` checks isolated host
capacity, verifies a supplied reviewed Ubuntu 26.04 cloud image and SHA256,
checks WSL disk/seed tools and the local SSH login public key, and performs
no writes. Its separately approved `-Mode CREATE` uses the existing WSL
`qemu-img`/`cloud-localds` helper and boots a generation-2 Ubuntu VM on
Hyper-V Default Switch, in `C:\Sentinel\E2E-Disposable`. The seed carries
an independent per-VM nonce and configures an SSH user and version-pinned
Ubuntu KVP daemon package. No automatic cleanup or destructive rollback.

Stage 2 stores an approved Ubuntu image under a SHA256 **digest filename**,
not the original upstream name. Confirm its path and matching digest with
the local private Stage 2 configuration (do not put private settings in git):

```powershell
$config = Get-Content .\infrastructure\level1\config\lab.json -Raw | ConvertFrom-Json
$digest = [string]$config.image.expectedSha256
$image = Join-Path $config.paths.imageCache ("ubuntu\26.04\$($config.image.buildId)\$($digest.ToLowerInvariant()).img")
[pscustomobject]@{
  ImagePath = $image
  Exists = Test-Path -LiteralPath $image -PathType Leaf
  ExpectedSHA256 = $digest
  ActualSHA256 = if (Test-Path -LiteralPath $image -PathType Leaf) { (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash } else { 'MISSING' }
} | Format-List
```

Only when the expected and calculated digest match should the isolated
provisioner be planned. Replace the two placeholders with the verified
values (one PowerShell line or backticks for continuation):

```powershell
.\infrastructure\level1\tools\New-SentinelDisposableE2E.ps1 -Mode PLAN `
  -ImagePath '<verified-Stage-2-cache-path>' `
  -ImageSHA256 '<reviewed-64-character-sha256>'
```

After a successful plan and explicit approval for a distinct VM, use
`-Mode CREATE -Approval CREATE_DISPOSABLE_SENTINEL_E2E_SSH01`.
It prompts for exact confirmation. A partial failure leaves artifacts for
manual inspection and never deletes or adopts resources. **Creating this VM
is not a full SSH/KVP end-to-end PASS.** We still need verified Hyper-V KVP
interoperability, correctly bound fresh evidence collection, and network SSH
identity checks. Do not use the older Stage 3 `infra-provision` to perform
this acceptance; its two pinned names are occupied by the working lab.
