> This public README uses fictional example inventory. Run actual infrastructure operations only with separately approved private configuration and validated resource safeguards. The currently imported legacy PowerShell modules still contain environment-specific constants and are being reviewed for extraction.

# Sentinel — Level 1 Infrastructure Provisioning Pipeline

**Status:** Stages 1–3 (preflight, approved image cache, isolated Hyper-V VM provisioning and authenticated guest health) implemented and previously exercised in the local lab. Stage 4 Ansible and subsequent Kubernetes automation are **not implemented**. The repository import has not yet been end-to-end revalidated from this new path.

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
