# Stage 5.5 — Rebuild a Kubernetes worker from a fresh VM (planned)

**State:** Discovery/preflight implemented **read-only**. Worker replacement, KVP migration to an actual cluster worker, and fresh kubeadm rejoin remain **NOT IMPLEMENTED**. Absolutely no permission to remove the existing `sentinel-l1-w01`.

## Why Stage 5.4 does not authorize deleting the cluster

Stage 5.4 demonstrated zero-touch initial bootstrap for isolated **disposable** VMs named `sentinel-e2e-auto20..29` at `10.78.0.20..29`. It did not replace the joined worker `sentinel-l1-w01` (`10.78.0.11`) or automate cluster Node-object rotation. The publisher and trust verifier explicitly *reject* names/IPs outside the disposable range. Do not change that allowlist to include a live worker without new replacement and freshness guarantees.

The current `130-reconcile-worker.yml` handles either a fully unjoined, absent Node object or a consistent already-joined worker, but rejects **mixed state**. Reusing the old Kubernetes worker name with a fresh identity requires an explicitly approved, safety-checked old Node-object removal step after workloads are safely moved and backup/recovery evidence is available. Kubernetes control-plane state must be preserved.

## Stage 5.5 implementation plan

1. **5.5.0 — host inventory/ownership PLAN (implemented).** Pin UUIDs for the current worker and protected control plane. Validate Running VM state, two NICs per VM, existing switches, exact worker disk ownership, shared disks and checkpoints. Output is host-only evidence; `DestructionApproved: False` always. This does not query Kubernetes.
2. **5.5.1 — Kubernetes read-only workload/storage inventory (implemented, acceptance incomplete).** `infrastructure/ansible/playbooks/160-worker-rebuild-plan.yml` uses an already trusted private Ansible inventory to observe the two Ready nodes, existing worker Kubernetes Node UID, worker Pod placements and counts of PVs, PVCs, local/hostPath PVs and PDBs. It never approves deletion or changes Kubernetes. Separate analysis still needs to identify workload ownership, drain/PDB feasibility, reclaim policies, backups and unsaved data; no cluster changes are authorized by this audit.
3. **5.5.2 — worker-specific first-boot provisioning (not built).** Generalize *reviewed and fully tested* Stage 5.4 cloud-init/KVP **without weakening its strict disposable allowlists**. Pin the new VM UUID, independent nonce, per-VM user login key, new SSH host public key, proper private IP/MAC, signed Ubuntu package provenance and no trust-on-first-use. Keep replacement worker public identity records separate from old known_hosts; reject an unchanged/ambiguous key or stale KVP record.
4. **5.5.3 — separate, approval-gated retire/recreate (not built).** Cordon/drain with observed bounded completion and PDB respect (never force-delete data-bearing Pods), verify protection of control-plane and etcd, gracefully unregister **only** exact approved worker VM/disks, verify no reparse points/foreign attachments and stale DHCP/ARP uniqueness, then recreate the fresh worker. Break each non-reversible operation behind an explicit authorization boundary; no auto-delete on a failed rejoin.
5. **5.5.4 — no-touch-to-control-plane configuration and join (not built).** Through independent KVP-attested, pinned SSH, apply approved OS/containerd/Kubernetes packages to the new worker only, confirm the control plane is healthy, safely retire the old Kubernetes Node UID (with independent approval), mint a short-lived join token through the control plane, run `kubeadm join` exactly once. Do not run `kubeadm init`, `kubeadm reset`, delete etcd or rewrite trusted records on the control plane.
6. **5.5.5 — acceptance and failure recovery (not built).** Reconcile two intended Ready nodes, exact fresh node UID/internal IP, kubelet version, Flannel 2/2, CoreDNS, cross-node connectivity, workload restoration, audit evidence and partial-failure behavior. Repeated fresh worker builds without manual guest SSH or package installation are required before declaring reliable repeatability.

## Run the read-only host preflight

From Administrator PowerShell using the *Stage 5.5* code checked out locally:

```powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform
$cp = Get-VM -Name 'sentinel-l1-cp01' -ErrorAction Stop
$worker = Get-VM -Name 'sentinel-l1-w01' -ErrorAction Stop
.\infrastructure\level1\tools\Test-SentinelStage55WorkerRebuild.ps1 -Mode PLAN -ExpectedWorkerVMId $worker.Id -ExpectedControlPlaneVMId $cp.Id
```

This can print **`STAGE55_HOST_PLAN_READY`**, followed by **`STAGE55_DELETE_BLOCKED`**. The former means host metadata checks passed, not that deletion is safe; the latter is mandatory until the separate Kubernetes/storage and automated replacement gates are implemented and tested. There is deliberately no `RUN`, `DELETE` or `APPLY` mode yet.

## Required acceptance signals (future)

`STAGE55_WORKLOAD_SAFETY_PASS` → `STAGE55_NEW_WORKER_KVP_VERIFY_PASS` → `STAGE55_PINNED_SSH_PASS` → `STAGE55_WORKER_CONFIG_PASS` → `STAGE55_KUBEADM_REJOIN_PASS` → `STAGE55_WORKER_READY` → `STAGE55_E2E_PASS`.

The first live destructive test must be performed on a separately owned disposable worker replica or after the exact working worker's data and Kubernetes responsibilities have been proven disposable with a rollback plan. The control-plane VM is **never** the deletion target.
