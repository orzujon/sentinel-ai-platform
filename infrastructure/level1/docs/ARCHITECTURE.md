# Sentinel Level 1 — provisioning architecture

## Objective

Build a fully reproducible *second* Kubernetes environment using disposable, isolated Hyper-V resources, without taking over or modifying the existing `example-existing-cp` and `example-existing-worker` machines. Legacy preflight, image-cache and isolated VM provisioning components exist. The public-source separation remains incomplete until all environment-specific runtime constants are migrated into private policy.

## Two planes: never create a circular dependency

```text
WINDOWS 11 MANAGEMENT HOST (survives sandbox deletion)
  sentinel.ps1 + config/lab.json + runs/<run-id>/
        |
        v
  [00 preflight] --fail closed--> [10 host bootstrap] --> [20 approved image cache]
        |                                                      |
        v                                                      v
  report JSON/JSONL       [30 isolated network] --> [40 2 VMs] --> [50 cloud-init]
                                                                        |
                                                                        v
                              [90 publish] <-- [80 validate] <-- [70 kubeadm] <-- [60 Ansible]

ILLUSTRATIVE SANDBOX WORKLOAD PLANE (fictional identifiers):
  Internal switch Example-Isolated, host 192.0.2.1/24
  example-cp: 192.0.2.10/24     example-worker: 192.0.2.11/24

PROTECTED, EXISTING WORKLOAD PLANE (never targeted):
  Example-Existing, 198.51.100.0/24, example-existing-cp, example-existing-worker
```

The eventual **control-plane API** will live inside sandbox Kubernetes; the **provisioning pipeline** and its evidence must remain on the Windows host (and later off-host backup).

## Stage contract

Every implemented stage receives (1) a typed, non-secret configuration, (2) its `runId`, (3) an allowlist of target resources and (4) outputs from required predecessor stages. It returns:

- `PASS`/`WARN`/`BLOCK` checks and a terminal state: `READY`, `READY_WITH_WARNINGS` or `BLOCKED` for preflight.
- A JSON report and structured JSONL events with timestamp, check ID, status and human-readable reason.
- A nonzero exit code when blocked; no downstream stages run after a blocker.
- An idempotency policy and an explicit ownership check for any resource it might create.

Logs do **not** contain passwords, kubeadm tokens, SSH private keys or kubeconfigs. They are created under `runs/` and ignored by Git.

## Read-only preflight implemented now

`sentinel.ps1 preflight` invokes `src/Sentinel.Preflight.psm1`. Checks:

- Allowed Windows edition, total/free RAM and available logical processors.
- Budget: two proposed 4 GiB startup-memory guests + host RAM reserve; four guest vCPUs + CPU reserve.
- Storage: conservative 2 × 60 GiB planned disks + 20 GiB host free-space reserve.
- Elevation, Hyper-V feature state and read-only Hyper-V module/host access.
- Existing VM inventory: any collision with proposed names fails; protected `k8s-*` VMs are reported only.
- Existing virtual switch collision and IPv4 route overlap with the new sandbox `192.0.2.0/24` subnet.
- Basic WSL executable availability; missing Ubuntu/Ansible installation is a later-stage check.
- Golden image SHA256 pin presence (WARN until acquired and verified; image stage will hard-stop without it).

**No downloads, Hyper-V feature enablement, VM creation, switch creation, VM starts/stops, SSH connections, Ansible runs or Kubernetes mutations.** Only `runs/` evidence is written.

## Future execution controls

- `10-host-bootstrap` supports controlled pause/resume for Windows reboot; it never restarts the PC without explicit approval.
- `20-image-cache` verifies a pinned SHA256 before image use and reuses the cached artifact.
- `30` and `40` only create resources with names in `lab.json`, and refuse unsafe reuse or name collisions.
- `50-cloud-init` creates different machine IDs and SSH host keys; no baked-in shared machine identity or secrets.
- `60-ansible` verifies hostname, machine-id, IP and MAC mapping before escalating privileges; invoke existing playbooks but only against sandbox inventory.
- `70-kubernetes-bootstrap` pins Kubernetes package versions and avoids rerunning `kubeadm init` on partial state without review.
- `80-validate` captures API readiness, both nodes, CoreDNS/Flannel health and cross-node Pod checks.
- `90-publish` retains metadata outside disposable VMs; secrets redacted.

## Recovery and ownership

Start/Stop of the *existing* lab is a separate operation from provisioning and rebuilding. Backups of etcd and any future application data will be a **separate recovery capability**, stored outside VM disks. Never assume a PVC on a local VM disk is a disaster-recovery backup.

On partial failure, stop immediately. Do not automatically delete working resources, reset kubeadm or overwrite a conflicting VM. A future explicit, independently approved sandbox-destroy operation will require owner labels/IDs, checks that targets are not protected, backup confirmation and its own audit trail.
