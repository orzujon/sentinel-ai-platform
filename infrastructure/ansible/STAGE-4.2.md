# Stage 4.2 — Ubuntu baseline and containerd (controlled rollout)

**First increment: read-only discovery only.** The Stage 4.1 management
runner remains our trusted entrypoint. Do not install packages, change kernel
settings, disable swap or restart services until we have an explicit,
reviewed apply policy and the inventory inspection passes.

## Purpose

We need reproducible Ubuntu 26.04 amd64 Kubernetes nodes using containerd
with CRI enabled and a systemd-compatible cgroup driver. Containerd 1.x and
2.x have **different configuration schemas**, so we first discover the
exact version offered by the Ubuntu apt metadata rather than assuming it.
See https://kubernetes.io/docs/setup/production-environment/container-runtimes/

## Single-command, read-only discovery

From Windows PowerShell, using the Stage 4.2 feature branch:

```powershell
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 -ConfigRepo 'C:\PRIVATE-CONFIG-CLONE' -DiscoverBaseline
```

The command reuses the immutable private YAML revision, validates the
previously trusted SSH host keys, and runs Stage 4.1 guest readiness before
Stage 4.2 discovery. The inventory stays private inside WSL.

Automated checks include:
- Only Ubuntu 26.04+ amd64 systemd guests
- No pre-existing kubelet configuration or Kubernetes admin credentials
- Candidate package version from **current local apt metadata** (no apt update)
- Installed containerd version and existing `/etc/containerd/config.toml`
- Containerd service state, swap usage, IP forwarding and kernel version

The command prints one concise discovery summary per guest and
`STAGE42_DISCOVERED` on success. All discovery actions are read-only and
must report `changed=0`. Existing cluster detections are BLOCKED.

## Next controlled implementation (not in this increment)

After discovering both nodes' exact package candidates, we will implement
a **version-pinned, idempotent** Ansible apply with explicit operator
approval and a named, isolated target group. It will:

1. Require the same pinned image/config/host identity and reject existing
   Kubernetes nodes or unexpected pre-installed runtime configurations.
2. Install a deliberately selected Ubuntu containerd package revision,
   not the moving `latest`; verify containerd 2.x / runc compatibility.
3. Manage overlay and br_netfilter load-on-boot modules, IPv4 forwarding
   and Linux bridge netfilter settings.
4. Configure CRI and the systemd cgroup driver with the correct
   containerd-version-specific schema; ensure service is enabled/running.
5. Handle swap through an explicit policy decision (not a silent
   `swapoff -a`) and avoid touching existing fstab without review.
6. Validate the CRI socket, active service and a second convergent
   apply (`changed=0`). Retain logs and change decisions locally.

Ansible check mode can preview many but **not all** future effects. A
successful discovery or `--check` is *not* authorization to apply.

## Security boundaries

The previously operational Kubernetes hosts are not Stage 4 targets.
No environment-specific VM names, addresses, SSH keys, or filesystem
inventory should be committed to this public repository. All targets
are derived from the private YAML and fail-closed policy validator.
