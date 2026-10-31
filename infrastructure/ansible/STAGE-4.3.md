# Stage 4.3.1 — Kubernetes discovery (read-only)

**Status (2026-10-31): Stage 4.3.1 discovery complete. Stage 4.3.2 signed repository and pinned kubeadm/kubelet/kubectl installation/holds completed and confirmed on both isolated nodes. Stage 4.3.3 control-plane configuration and guarded init code is implemented; local plan validation is pending.**
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

## Stage 4.3.2 — next gate: pinned package installation simulation

The approved signed repository bootstrap completed on both isolated guests with
`kubeadm`, `kubelet` and `kubectl` each reporting candidate
`1.37.2-1.1`. This is newer than the initial v1.37.1 proposal. Installation
is **not** yet approved and no Kubernetes packages have been installed.

Run the **read-only** simulation from the public repository checkout:

```powershell
git pull --ff-only origin feature/stage43-kubernetes-discovery
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 `
  -ConfigRepo "C:\Sentinel\config-readonly" `
  -PlanKubernetesInstall
```

This reuses the pinned private inventory and existing SSH trust, validates
both nodes, checks the existing signing key fingerprint and signed repo,
requires the exact three package candidates, rejects existing package state,
runs `apt-get -s` to inspect the dependency transaction, rejects removals,
and saves private controller-local 0600 simulation reports. No guest package
installation or repository refresh is performed.

**Stop for review of BOTH private reports** (especially every `Inst`
entry). A simulation cannot guarantee the absence of package maintainer-script
side effects and is not an authorization to proceed.

An additional `-InstallKubernetesPackages` mode is implemented behind a
separate literal approval token. **Do not invoke it until the read-only plan
passes, dependency changes have been reviewed, and CI/local safety tests pass.**
The install uses the exact pinned `1.37.2-1.1` revision, processes one guest
at a time, applies package holds, and checks versions. It deliberately does
not run kubeadm init/join or apply a CNI. It is first-install only and will
reject a repeated invocation once Kubernetes packages exist. Recovery and
post-install observation must be reviewed before further work.

Stage 4.3.3 (control-plane initialization) remains blocked on CIDR review
outside the guests, selected private NIC IPs, firewall verification, and
separate bootstrap design and approval.

## Stage 4.3.3 — initialize the control plane (new implementation)

Reuse **the private pinned inventory** and previously validated network design.
The control-plane IP comes from the configured `ansible_host` of the existing
`sentinel_control_plane` group. No new static IP, virtual switch, VM,
containerd reinstall or network provisioning is performed. Kubernetes v1.37.2
is configured using the kubeadm `v1beta4` schema, containerd CRI socket,
node-ip, advertised API IP, Pod CIDR `10.244.0.0/16`, and Service CIDR
`10.96.0.0/12`.

Run **plan mode first**, from Windows PowerShell:

```powershell
git pull --ff-only origin feature/stage43-kubernetes-discovery
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 `
  -ConfigRepo "C:\Sentinel\config-readonly" `
  -PlanControlPlane
```

The command reuses the controller's previously trusted SSH inventory and
verifies package versions on both nodes. On the control plane only, it checks
initialization markers, confirms the expected private IP is present and calls
`kubeadm config validate` using stdin. Plan mode does not write a kubeadm
config, create join secrets, install packages or initialize the cluster.

**Application is a separate operator decision.** After plan output and
GitHub Actions are reviewed, `-InitControlPlane` with
`-ControlPlaneApprovalToken "INITIALIZE_SENTINEL_STAGE433_CONTROL_PLANE"`
runs the same preflight and then writes a root-only kubeadm configuration,
initializes the control plane with `--skip-token-print`, and checks
the API manifest. Neither Flannel nor worker joining is included. An initial
API server may be running but nodes remain NotReady until a CNI is installed.
If a partial init fails, stop for inspection instead of resetting and retrying.

Important: the old Kubernetes discovery path intentionally requires packages
to be absent. **Do not rerun Stage 4.3.1 or 4.3.2 bootstrap** on these
already-installed nodes. Use the new `-PlanControlPlane` mode.

## Stage 4.3.4 — pinned Flannel release plan

Control plane initialization was approved and passed locally on 2026-10-31. Run the -PlanFlannel switch through Invoke-SentinelReadiness.ps1 with the existing -ConfigRepo option. It verifies Kubernetes /readyz from the control-plane kubeconfig, checks that the Flannel DaemonSet does not yet exist, fetches the exact v0.28.10 release asset over TLS and prints SHA256 for operator review. This mode DOES NOT deploy anything. Review asset image references and interface selection before authorizing a separately gated deployment.

### Stage 4.3.4 approved Flannel deployment

After reviewing the exact checksum printed by the read-only plan and validating the release manifest's images and routing mode, operator approval may be provided via -ApplyFlannel, -FlannelSha256 with the full lowercase 64-hex checksum, and -FlannelApprovalToken APPLY_SENTINEL_STAGE434_FLANNEL_02810. The apply playbook checks /readyz, refuses an existing DaemonSet, verifies the fetched manifest against the operator-pinned SHA256, applies through kubectl stdin, waits for rollout, and verifies node Ready. Apply mode modifies the cluster. Do not run without reviewing the plan first. On partial failure stop and inspect state; do not reset or blindly rerun.

## Level 1 unified desired-state entry point (initial Flannel reconciliation)

The operator should no longer copy the Flannel checksum between plan and
apply. It is stored in the reviewed, version-controlled
`infrastructure/ansible/desired-state/lab.yml` lock file, separate from
the private environment inventory and credentials.

Single command for automatic inspection (no mutation):

```powershell
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 `
  -ConfigRepo "C:\Sentinel\config-readonly" -Reconcile
```

Single approved deployment/reconciliation command:

```powershell
.\infrastructure\ansible\Invoke-SentinelReadiness.ps1 `
  -ConfigRepo "C:\Sentinel\config-readonly" -Reconcile `
  -ReconcileApprovalToken "DEPLOY_SENTINEL_LEVEL1_LAB"
```

The pipeline uses private inventory and SSH trust, reads pinned desired state,
downloads and checks the release once on the WSL controller, retains its exact
bytes in private temporary storage during the run, and supplies that artifact
to Ansible. Ansible verifies its digest again, checks API readiness and
existing Flannel state, applies only when absent and explicitly approved,
checks rollout and node readiness, and annotates the release checksum.
A repeat run with matching checksum verifies rollout and Ready without apply.
An existing unmanaged or mismatched Flannel release blocks; there is no silent
overwrite. The final private audit includes release, mode, result and exit code.

**Limitations:** This initial orchestrated reconciler covers the already-built
control plane and Flannel first install/reverification. It does not yet provision
fresh VMs through an end-to-end orchestrator, join the worker, or perform CNI
upgrades/rollbacks. Desired-state changes to an existing Flannel release are
blocked until a reviewed upgrade and recovery flow is implemented.
