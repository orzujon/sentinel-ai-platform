# Stage 4.3.1 — Kubernetes discovery (read-only)

**Status: implementation proposed, pending validation against the two sandbox VMs.**
Do not install Kubernetes packages, call `kubeadm init`/`join`, apply
Flannel, modify network settings or touch existing protected VMs in this step.

## Why discover before applying?

The Stage 4.2 containerd baseline is fully deployed, idempotent and survived
a reboot. Stage 4.3 will eventually establish a **single control plane +
one worker** using kubeadm, but an installation requires more decisions:
Kubernetes minor release and signed package repository, Pod/Service
addressing, node IP selection on dual-NIC guests, CNI manifest pinning,
required ports and secure bootstrap token handling.

Stage 4.3.1 collects read-only evidence so we can make those decisions.

## Entry point from Windows PowerShell

Run from the public checkout on the Stage 4.3 feature branch:

```powershell
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 `
    -ConfigRepo "C:\PRIVATE-CONFIG-CLONE" `
    -DiscoverKubernetes
```

The wrapper resolves the existing authenticated private configuration
`origin/main` commit, derives the sandbox-only inventory, validates
previously trusted host keys, and executes the Stage 4.1 readiness checks.
The Kubernetes discovery then inspects the two approved nodes over SSH.

The command uses narrowly scoped, read-only sudo for two inspections:
checking Kubernetes markers under the root-protected CNI directory and querying
the root-owned containerd socket. Other guest tasks remain unprivileged.
It does **not** refresh APT metadata, install Kubernetes packages, change
guest configuration or reboot VMs.
Ansible's `changed=1` for the report `copy` task means a **controller-local**
file was written in the private WSL state directory. The guests are not
changed.

## What is checked?

- Exactly one control-plane and one worker from protected, pinned private YAML
- Ubuntu 26.04 x86_64, no pre-existing Kubernetes manifests/kubelet config
- Presence of `kubeadm`, `kubelet`, `kubectl` in *existing* local APT
  metadata, and whether any Kubernetes packages are already installed
- Containerd `2.2.2-0ubuntu1.2`, active service, CRI plugin and socket
- No active swap; IPv4 forwarding enabled
- VM's expected private IP actually present on an interface
- Current guest IPv4 routes and existing Kubernetes TCP port listeners
- Proposed, **not yet approved**, Flannel Pod CIDR `10.244.0.0/16`
  and Service CIDR `10.96.0.0/12`: no overlap with the reported
  guest routes, existing private network or protected subnet list

Only the controller's private directory receives the per-node JSON reports
(mode 0600). Raw APT policy and interface data remain private; public Git
contains only discovery automation and non-secret proposals.

`PACKAGE_SOURCE_REVIEW` is expected if kubeadm is not in the guest's
current package cache. Missing package candidates are *not* permission
to silently add a repository or run `apt update`.

## Decisions before Stage 4.3.2

1. Review the supported Kubernetes minor release and pin exact kubeadm,
   kubelet and kubectl versions, sourced from the appropriate version-scoped
   `pkgs.k8s.io` repo. Agree on repository key trust and package hold policy.
2. Confirm Pod/Service CIDRs do not conflict with **Windows, WSL, guest
   routes, protected lab networks or external routed networks**. This guest
   discovery alone is not a substitute for examining the other networks.
3. Pin a compatible Flannel **release manifest** and its container images;
   do not apply unreviewed `latest` YAML.
4. Select the node-facing addresses on the private NICs and check
   anticipated API/control-plane/worker connectivity and firewall policy.
5. Design guarded install, control-plane initialization, worker bootstrap,
   safe token handling, separate operator approvals, and failure recovery.
6. Update the older `infrastructure/level1` README and stage registry after
   reviewing how Stage 4 maps into the legacy stage graph.

## Safe next milestones

- **4.3.1** Read-only discovery and package/network architecture review.
- **4.3.2** Reviewed, pinned kubeadm/kubelet/kubectl installation.
- **4.3.3** Single control plane initialized with approved kubeadm config.
- **4.3.4** Review/apply the pinned Flannel release CNI manifest.
- **4.3.5** Secure worker join with ephemeral bootstrap material.
- **4.4** Cluster, DNS, cross-node connectivity, idempotence and recovery tests.

Official references:
- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- https://github.com/flannel-io/flannel/blob/master/Documentation/kubernetes.md
