# Sentinel Guardian L1 — first controlled self-healing experiment

Status: **PR / offline demo only**. No fresh-cluster mutation has been performed.

## First visible experiment: a zero-replica outage

Kubernetes treats `spec.replicas: 0` as an intentional desired state: it will
not automatically restore a scaled-to-zero Deployment. Sentinel Guardian adds a
**separate, explicitly configured, synthetic recovery goal**: the
`sentinel-demo-api` Deployment in namespace `sentinel-healing-lab` should have
one replica. It detects a deliberate deviation and proposes one action:
scale from 0 to 1. If the state is anything else, it reports HEALTHY, ABSTAIN,
or BLOCKED rather than guessing what to do.

This experiment is a real Kubernetes state reconciliation, **not** an LLM
autonomously executing shell commands. The existing Sentinel AI API is still
read-only and generates advisory investigation reports only. A future
integration can consume Guardian's deterministic evidence; never treat an
LLM suggestion as authority to mutate resources.

## Run something interesting immediately — no cluster access needed

From the **current primary checkout**, after checking out the reviewed PR:

```powershell
cd C:\Users\Orzu\projects\sentinel-ai-platform
python -m unittest discover -s infrastructure/self_healing/tests -p 'test_*.py' -v
python infrastructure/self_healing/guardian.py --mode plan --snapshot infrastructure/self_healing/fixtures/zero-replica.json
```

Expected output: a compact JSON plan with
`"decision":"PROPOSE_SCALE_TO_ONE"`, a `planSHA256`,
`"fixedDesiredReplicas":1`, and `SENTINEL_GUARDIAN_MUTATIONS: 0`.
No kubeconfig, credential or network is used in this offline mode.

## Controlled live lab — later, with your permission

The included `sentinel-demo.yaml` is a synthetic, nonprivileged BusyBox HTTP
Deployment + ClusterIP Service in a separate namespace. There is no Ingress,
RoleBinding, ClusterRole, service-account token or production workload.
Its container uses a restricted security context and 1 replica by default.

Before any creation, **do not assume a WSL Kubernetes context is configured**:
the existing fresh-cluster Ansible runner obtains access through
identity-pinned SSH to the control plane, not necessarily through your local
`kubectl`. We must first establish a read-only, identity-verified
kubeconfig/context for this new workflow, inspect the exact two fresh nodes,
and separately approve installation of the disposable manifest. No code in
this PR automatically obtains broad cluster-admin credentials or alters
the running cluster.

Only after that setup and a reviewed installation plan can the operator:

1. Install **only** `sentinel-demo.yaml` by an explicitly approved
   `kubectl apply` on the right context; verify the lab namespace,
   Deployment and Service are healthy. No existing cluster components change.
2. Deliberately induce a synthetic outage by scaling
   `sentinel-demo-api` from one replica to zero, under a separate
   operator approval. The lab HTTP service becomes unavailable.
3. Run Guardian read-only with explicit `--context <verified-context>`:
   `python infrastructure/self_healing/guardian.py --mode plan --context <verified-context>`.
   Guardian queries nodes, namespace and Deployment, verifies both fresh
   nodes are Ready, verifies exact namespace and Deployment name, immutable
   UIDs, marker labels, and declared goal, then prints a digest-bound plan.
4. Review the plan. Only a **separate explicit operator action** with
   `--mode apply`, `--approval HEAL_EXACT_SENTINEL_DEMO`, the exact
   `--expected-plan`, `--expected-namespace-uid`, and
   `--expected-deployment-uid` can request one guarded scale.
   The command includes Kubernetes `--current-replicas=0` and
   `--resource-version=...` compare-and-swap conditions.
5. Guardian re-reads live cluster identity and the desired replica count.
   It reports action acceptance; **that is not yet evidence of application
   readiness**. Observe the Deployment's available replica, HTTP response,
   and end-to-end recovery time separately.

The exact approval operands must come from the new *live* PLAN output.
**Never reuse fixture UIDs or their hashes in a live command.**

## Failure policy

- Wrong Kubernetes context / unexpected node set → BLOCKED
- Missing namespace/Deployment, unexpected UID, deleting object → BLOCKED
- Missing `sentinel.ai/demo-only=true` label → BLOCKED
- Missing `sentinel.ai/desired-replicas=1` annotation → BLOCKED
- Replica count not `0/0` or `1/1` → ABSTAIN (no write)
- Changed resource version/plan hash → BLOCKED (no write)
- Failed scale request or uncertain postcondition → BLOCKED (no retry)
- No automatic shell execution, no namespace deletion, no rolling restarts,
  no unrelated workloads, no background controller or remediation loop

The tests use synthetic JSON and mocked calls. Both GitHub Actions and
operator offline acceptance must pass before designing a live experiment.
Clean BOOTSTRAP/rebuild validation remains a separate future milestone;
do not run BOOTSTRAP against existing `sentinel-fresh-*` VMs.

## Future research track

Collect response-time and availability baselines before and after induced
failures. Distinguish detection time, decision time, approval delay,
Kubernetes convergence, and HTTP restoration. Compare manual-only recovery
with Guardian-assisted recovery under the *same* synthetic failure type.
The first live integration must also restrict Kubernetes RBAC to
`get` on the scoped resources and `patch`/scale on the single demo
Deployment; until then, no apply action should be authorized using an
unrestricted administrative kubeconfig.
