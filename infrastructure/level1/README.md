# Sentinel — Level 1 Infrastructure Provisioning Pipeline

**Status:** `00-preflight` implemented; later stages designed but **not implemented**.

This is a read-only, observable first stage toward an automated Hyper-V → Ubuntu → Ansible → kubeadm → Flannel → Kubernetes provisioning pipeline. It uses a new, isolated sandbox namespace and **never touches your existing** `k8s-cp01`, `k8s-w01`, `Sentinel-K8s` switch or `10.77.0.0/24` private network.

## Files

```text
sentinel-level1/
├── sentinel.ps1                  # Windows PowerShell entry point
├── config/
│   ├── lab.json                  # Non-secret desired sandbox specifications
│   └── stages.json               # Stage DAG and implementation flags
├── src/
│   └── Sentinel.Preflight.psm1   # Read-only checks + JSON/JSONL reporting
├── docs/
│   └── ARCHITECTURE.md
├── tests/
│   └── Test-StaticSafety.ps1     # Script parsing, configuration and isolation checks
└── runs/                         # Host-side run evidence (Git-ignored)
```

## Run Level 1 from Windows

Extract into a new folder, e.g. `C:\Sentinel\Automation\Level1`. **Windows PowerShell Administrator** (not WSL):

```powershell
cd C:\Sentinel\Automation\Level1
.\tests\Test-StaticSafety.ps1    # offline syntax and safety checks
.\sentinel.ps1 preflight          # READ-ONLY: no VM or network changes
.\sentinel.ps1 runs               # show stored runs
```

If downloaded PowerShell files are blocked by Mark-of-the-Web, inspect them and use `Unblock-File` on the files you trust rather than disabling system-wide policy.

The preflight returns exit code **2** on a blocker and **0** if ready (possibly with warnings). `runs/<UTC-run-id>/preflight.json` is the machine-readable report; `events.jsonl` contains each check with its timestamp. The run directory is the ONLY write destination.

**What to expect on your current machine:** Windows 11 Pro, Hyper-V and two existing VMs should be observed. Whether preflight passes depends on *current* free RAM, free disk and route conflicts—it is not inferred from historic system specs. Protected existing VMs are never treated as the proposed sandbox targets.

## Lab defaults — safe separation

- Future sandbox VM names: `sentinel-l1-cp01`, `sentinel-l1-w01`.
- Future internal switch: `Sentinel-L1`.
- Future subnet: `10.78.0.0/24` (host `.1`, nodes `.10`, `.11`).
- VM budgets: 4 GiB startup each, 2 vCPU each, 60 GiB dynamic VHDX capacity each.
- Planned VM storage: `C:\Sentinel\Level1-Sandbox\VMs` (not your existing VM directory).
- Original Kubernetes remains at `10.77.0.0/24` (`k8s-cp01` and `k8s-w01`).

The configuration **must not** include any secret values. The Ubuntu image digest is intentionally unset until the future image stage verifies it. This generates a warning at preflight and will block image acquisition when implemented.

## Important scope boundaries

- `sentinel.ps1` only supports `preflight` and `runs`. It does not yet support `provision`, `apply`, `build`, `destroy` or `restore`.
- Run reports are on the Windows host under the project folder; avoid sharing full logs from private enterprise machines.
- No full backup or restore solution exists yet; a disposable test environment must never become the only home of important data.
- Read architecture notes before implementing stage 10 or beyond. Provisioning stages require explicit safety controls and human approval before any Windows reboot or destructive change.

## Prerequisites

PowerShell 5.1+ on Windows 11 Professional/Enterprise, elevated for feature/Hyper-V inspection. Later stages may require WSL Ubuntu and Ansible, but preflight does not install either. Requirements are based on Microsoft Hyper-V requirements: https://learn.microsoft.com/virtualization/hyper-v-on-windows/reference/hyper-v-requirements
