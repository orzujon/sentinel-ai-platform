# Stage 4.3.1 — Kubernetes discovery (read-only)

**Status: Stage 4.3.1 verified on both sandbox guests (2026-10-31); Stage 4.3.2 read-only package-source plan pending local validation.**
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

## Stage 4.3.1 result (2026-10-31)

Both sandbox guests passed strict identity, containerd 2.2.2 baseline, CRI,
swap=0 and IPv4 forwarding checks. No existing Kubernetes installation
was detected. `kubeadm`, `kubelet`, and `kubectl` were absent from
the existing APT cache on both guests. Proposed Pod/Service ranges did not
overlap with guest or protected lab networks inspected. The review of
Windows/WSL/external network overlaps remains outstanding.

## Stage 4.3.2 first increment — read-only repository source plan

Official Kubernetes release documentation currently shows v1.37 as a
supported minor, and v1.37.1 as its documented stable patch. This is a
**version proposal**, not an approved exact Debian package version. Before
installing anything we must read *signed APT metadata* from both guests and
verify the full exact package revision for `kubeadm`, `kubelet`, and
`kubectl`. Do not guess a `-1.1` suffix.

Use the dedicated minor-scoped repository:
`https://pkgs.k8s.io/core:/stable:/v1.37/deb/`
with the vendor's `Release.key` under the `signed-by` keyring pattern.
Do not use deprecated `apt.kubernetes.io` or `apt-key add`.

**Read-only plan command from Windows PowerShell:**

```powershell
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 `
    -ConfigRepo "C:\Sentinel\config-readonly" `
    -PlanKubernetesPackages
```

This command reruns Stage 4.1 and 4.3.1 guest validation, then checks:
the `/etc/apt/sources.list.d/kubernetes.list` and
`/etc/apt/keyrings/kubernetes-apt-keyring.gpg` files, package signing
utilities, existing package holds, and HTTPS certificate-validated
reachability of the official minor-scoped signing-key endpoint. It does
**not** write a trusted key, add an APT repo, run `apt update`, or install
any packages. Only private `0600` WSL-controller reports are created.
An HTTPS GET validates connectivity and certificates but **does not by
itself authenticate the signing key's provenance**; explicit review of
the upstream vendor key and of signed package metadata is still required.

**Next separate, approval-gated apply design:**

1. Confirm no conflicting `kubernetes.list`, keyring, or alternate Kubernetes
   repositories are already configured, and review authentic key identity.
2. Install required TLS/GPG tooling only after an approved package plan.
3. Install the reviewed signing key under `/etc/apt/keyrings/`; configure a
   `signed-by` source for v1.37 without overwriting unrelated files.
4. Refresh only after the approved repository change and inspect APT policy,
   origin/signature, dependency changes, and exact package revision on both VMs.
5. Propose a *separate* approved install of exact matching package versions,
   mark them held and verify. A kubelet that starts but has no cluster
   configuration is expected until Stage 4.3.3.
6. `kubeadm init`, Flannel and `kubeadm join` are **explicitly out of scope**
   for Stage 4.3.2.

Source:
https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/

## Approved repository bootstrap (separate from the read-only plan)

After reviewing the successful read-only plan, an operator may **explicitly
approve** a first-time Kubernetes v1.37 APT repository setup:

```powershell
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 `
    -ConfigRepo "C:\Sentinel\config-readonly" `
    -ConfigureKubernetesRepo `
    -RepositoryApprovalToken "CONFIGURE_SENTINEL_STAGE432_K8S_REPO"
```

**The command changes the two sandbox guests** by creating the Kubernetes
keyring and APT source files and refreshing APT package indexes. It does not
install kubeadm, kubelet, kubectl, or initialize Kubernetes.

The controller first runs strict SSH identity and readiness validation, the
Stage 4.3.1 Kubernetes empty-cluster discovery, and the Stage 4.3.2
repository-source plan on **both** approved guests before changing either.
The Ansible playbook then has a second all-host read-only preflight that
rejects existing or partial Kubernetes repository setup, scans Debian source
list locations for conflicting Kubernetes sources, fetches the official
Release.key over verified HTTPS, and checks the key's exact pinned primary
fingerprint `DE15B14486CD377B9E876E1A234654DA9A296436` before any source
registration.

The pinned fingerprint is corroborated in Kubernetes community discussions:
https://github.com/kubernetes/website/issues/42718
and should be re-reviewed after any documented signing key rotation.

Approved mutation is serialized one guest at a time. The playbook writes a
root-owned keyring and a `signed-by` source for **v1.37 only** and refreshes
APT indexes with normal signature verification enabled. Exact available
`kubeadm`, `kubelet`, `kubectl` candidates are reported to a private
controller directory for cross-node version comparison. No package
installation follows from this operation.

**Fail-closed recovery:** Existing/partial source or keyring files cause
future first-time bootstrap attempts to fail rather than overwriting them.
This first-time bootstrap is intentionally one-shot; a separate read-only
verification and managed rerun path will be required before claiming
post-apply idempotence. If a network, GPG or APT error occurs after the
first guest is configured, stop and manually reconcile the observed state.
Do not delete a keyring or rerun with disabled TLS/signatures just to get
past the gate.

**Next gate:** pin the exact Debian package revision actually reported
from signed APT metadata on *both* guests, assess dependencies and
review a separate Kubernetes package installation. That installation
still requires its own explicit approval and will not be included in
repository bootstrap.

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
