# Stage 4.2 — idempotent Ubuntu/containerd baseline (approval gated)

This stage targets only the private-YAML-validated **isolated sandbox** guests.
The previously existing Kubernetes VMs and networking remain protected.

## Verified discovery on 2026-10-30

Both sandbox guests reported:
- Ubuntu 26.04 amd64; containerd not installed; no runtime config
- `containerd` candidate: `2.2.2-0ubuntu1.2`
- Swap: 0; IPv4 forwarding: 0
- Both hosts passed Stage 4.1 SSH identity and guest readiness checks

The package revision is **pinned in reviewed source code**; changing it requires
a code review. The `containerd-stable` alternative is *not* selected.

## Read-only plan — first operator action

From PowerShell on the `feature/stage4-ubuntu-runtime-baseline` branch:

```powershell
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 -ConfigRepo 'C:\PRIVATE-CONFIG-CLONE' -PlanBaseline
```

The plan first reruns read-only Stage 4.1 and Stage 4.2 discovery, verifies
that both Ubuntu guests still offer the exact pinned revision, inspects
swap and existing runtime state, validates the install playbook syntax,
and emits `PLAN_ONLY`.

**No packages, services or guest configuration are changed by the plan.**
The plan is a description of intended actions, not an Ansible check-mode
guarantee or a fully simulated APT transaction.

## Explicit apply — only after reviewing the plan and approving changes

The following command intentionally changes the two sandbox VMs; do not
run it as part of discovery:

```powershell
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 `
    -ConfigRepo 'C:\PRIVATE-CONFIG-CLONE' `
    -ApplyBaseline `
    -ApprovalToken 'APPLY_SENTINEL_STAGE42_TO_SANDBOX'
```

The controller rejects missing/incorrect approval, then revalidates the
private config revision and SSH trust, checks both hosts, and runs **both
guests' full read-only preflight before changing either**. It will fail
rather than touch a host with existing Kubernetes credentials/kubelet
configuration, unexpected installed containerd revision, unmanaged
`/etc/containerd/config.toml`, enabled swap, or missing package candidate.

The approved apply uses `serial: 1` and Ansible's `become` to:

1. Install exactly `containerd=2.2.2-0ubuntu1.2` from existing signed
   configured APT indexes, with no package cache refresh, no intentional
   upgrade, downgrade or package removal. APT may install required
   dependencies and start the packaged service.
2. Load and persist `overlay` and `br_netfilter` modules.
3. Persist and activate `net.ipv4.ip_forward=1` and
   `net.bridge.bridge-nf-call-iptables=1`.
4. Manage a `version=3` containerd 2.x CRI config with the
   `io.containerd.cri.v1.runtime` plugin, `runc` and
   `SystemdCgroup=true`.
5. Restart containerd only when the managed runtime config changes,
   keep it enabled, and assert the pinned installed revision, active
   service and registered CRI plugin.

It deliberately does **not** disable swap, rewrite `/etc/fstab`,
install kubeadm/kubelet, initialize a Kubernetes cluster or modify
Windows Hyper-V resources.

## Acceptance and rerun contract

- First approved run: both sandbox VMs report `failed=0`,
  `unreachable=0`, with expected configuration changes.
- Second identical approved run: both VMs report `changed=0`.
- Repeat checks after VM reboot to ensure modules, sysctls and runtime
  survive restart.
- Failure midway is possible even with the all-host preflight and serial
  application; do not assume automatic rollback. Inspect the recap and
  guest state before retrying. The playbook is designed for convergent
  retries, not transactional rollback.
- PR #8 stays draft until the local plan, approved apply and
  idempotence validation are completed.

The official config references are
https://kubernetes.io/docs/setup/production-environment/container-runtimes/
and https://containerd.org/docs/2.3/cri/config/.
