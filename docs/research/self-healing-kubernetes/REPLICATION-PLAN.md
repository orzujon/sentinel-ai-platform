# Sentinel Research Track: Self-Healing Kubernetes

**Status:** DESIGN / REPLICATION PROTOCOL ONLY — NOT EXECUTED  
**Owner:** Sentinel AI Platform (independent lab)  
**Protocol version:** 0.1 (2026-11-02)  
**Target:** Isolated Hyper-V, Ubuntu and kubeadm cluster previously validated in Level 1 Stage 4; not a production platform.

> This document is a pre-registered *proposed* protocol. No test workload, observability agent, chaos tool, VM action or Kubernetes modification is performed by publishing it. The exact live cluster state must be revalidated before running anything. The earlier Stage 5 checkpoint and disposable-worker work has not established safe, automated snapshot recovery; never use snapshots or destructive VM actions as the experiment's rollback.

## 1. Research question and claims boundary

**Question:** How effectively does native Kubernetes restore service availability after deliberately induced workload failures, and how much additional diagnostic/safety value do observed telemetry, read-only Sentinel analysis and human-approved recovery add?

Hypotheses, fixed before data collection:

- **H1 (native):** a Deployment-owned Pod/container failure is recovered by Kubernetes without changing the Deployment template.
- **H2 (negative control):** an invalid image or persistent bad configuration is *detected but not repaired* by Kubernetes alone.
- **H3 (diagnosis):** an evidence-labelled diagnostic workflow can identify failure classes and recommend relevant safe checks more consistently than an unguided operator baseline.
- **H4 (governance):** an allowlisted, approval-gated remediation pathway can reject all out-of-scope targets in a designed negative-test suite, with auditable reasons.

Do not assert H1–H4 are true until the corresponding tests complete. This is an **adapted replication**, not a bit-for-bit reproduction of the cited dissertations. Lab size, control-plane topology, CNI, load and fault injectors differ.

## 2. Research anchors and differences

1. **Oluseyi Iyetomide Simon Coker, 2025**, *Evaluating Kubernetes Built-In Self-Healing Across Local and Cloud Environments Under Common Microservice Failure Scenarios*, MSc, National College of Ireland: a clean baseline, Pod crash, resource pressure and network impairment under sustained load, measuring recovery, throughput and latency. Original Minikube/K3s setups; Sentinel keeps our kubeadm/Flannel sandbox. https://norma.ncirl.ie/9694/
2. **Suyog Rajesh Redkar, 2025**, *Enhancing Resilience of Terraform-Provisioned Kubernetes Cluster using Chaos Engineering*, MSc, National College of Ireland: controlled fault experiments with LitmusChaos, Prometheus and Terraform/EKS. Sentinel initially uses manually reviewed, namespace-scoped injectors without privileged chaos controllers. https://norma.ncirl.ie/9730/
3. **Prasanna Pankaj Shinde, 2025**, *Self-Healing CI/CD Pipelines: Automating Kubernetes Deployments with Terraform and Ansible*, MSc, National College of Ireland: classification, health scoring, OPA-based policy and rollback evaluation. Sentinel adapts the evaluation categories but **retains human approval** for all remediations. https://norma.ncirl.ie/9267/
4. **Kubernetes upstream**: self-healing, probe semantics and Deployment ProgressDeadlineExceeded explicitly distinguish normal recovery, traffic exclusion, and stalled rollouts that are merely reported. https://kubernetes.io/docs/concepts/architecture/self-healing/ ; https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ ; https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
5. **Chaos Mesh docs (future option)**: namespace filters are not enabled by default and chaos-daemon requires powerful node access. Review before installing; avoid on shared or non-disposable clusters. https://chaos-mesh.org/docs/next/configure-enabled-namespace/

Read and cite the dissertations' configuration manuals before claiming method-level replication. Publication year and full source title are recorded here for attribution.

## 3. Starting point: reused Sentinel assets

Already present in public source:
- Hyper-V/Ubuntu: infrastructure/level1/ ; separately guarded provisioning, preflight and bootstrap-plan / bootstrap-verify design.
- Ansible: infrastructure/ansible/ ; trust-validated private inventory, guest baseline, Kubernetes package pinning and reconciliation scripts.
- Kubernetes checks: infrastructure/ansible/playbooks/140-cluster-validate.yml and 150-active-network.yml ; previously exercised cluster, DNS and cross-node workload checks.
- AI: FastAPI, Ollama, deterministic curated runbook retrieval and mechanical quality checks. Existing CI and four-case synthetic evaluation.
- Existing validation is a **historical lab observation**, not a current live health assessment. Stage 5 clean-room orchestration is incomplete.

**Expected topology for preflight:** one kubeadm control-plane VM and one worker VM, with Flannel and CoreDNS. A single control plane is a single point of failure. Unless changed with separate approval, ordinary workload replicas may all run on the one worker. **This project does not test node-level high availability, etcd disaster recovery or control-plane self-healing.**

Control separation:
- Windows/WSL management host: experiment orchestration, read-only evidence capture, run manifests and approval record.
- Dedicated Kubernetes namespace: synthetic HTTP workload and its purpose-built fault controls.
- Independent synthetic client: makes timestamped requests through a reproducible Service access path; client uptime is monitored.
- Optional isolated metrics collector: metrics-server/Prometheus only after compatibility and RAM budget review.
- Sentinel AI API: initially remains **outside** the cluster and receives sanitized incident snapshots, not kubeconfig credentials.

## 4. Study design and comparison arms

A. **Native-only control:** normal Kubernetes reconciliation; capture exact native behaviour and impact. No Sentinel advice used during recovery.
B. **Native + observability / read-only diagnosis:** same workload and faults; capture metrics and deterministic/Sentinel hypotheses. Sentinel is *not* allowed to mutate the cluster. Compare diagnosis metrics and observation time, NOT native recovery time as if Sentinel caused it.
C. **Approval-gated recovery:** only for faults not automatically repaired; an operator reviews a deterministic recovery proposal, scope, expected old/new state and rollback, authorizes one specified change and verifies results. Report human wait time separately from execution time.

Repeat each scenario initially **3 dry-run trials** to validate harness and guards; then plan **10 measured trials per scenario per eligible arm**, randomized in reproducible seeded blocks. Number of trials may be increased based on dispersion. Never pool preliminary and measured trials. Each trial uses the same pinned app image, resource requests/limits, Service path, load profile, probes, sample rates and declared recovery policy. Randomize scenario order, with a clean-state reset and cooldown between trials.

This is a single-lab experiment, not an industry-wide performance comparison; avoid causal claims from changes in hardware, topology or load.

## 5. Experimental workload and load

**Proposed namespace:** sentinel-resilience-lab; require that it does not already exist and is independently approved for ownership. Synthetic HTTP app should expose:
- GET /healthz — process liveness only;
- GET /readyz — actual ability to serve simulated transactions;
- GET /work — deterministic synthetic transaction with request ID;
- test-only restricted controls for *application-scoped* failures, never node/host/network modification.

Proposed Deployment: start with 1 replica for obvious replacement dynamics; repeat selected tests at 2 replicas to measure Service continuity. Use fixed image SHA256 digest, startup/readiness/liveness probes, controlled progressDeadlineSeconds, explicit CPU/memory requests and limits, and a Service with stable discovery. A two-replica Deployment on a single eligible worker is **not worker-node redundancy**.

Security template: run as non-root, prevent privilege escalation, drop Linux capabilities, default seccomp profile, read-only root filesystem where practical, restricted service account, no secret mounting or external credentials, no hostPath, hostNetwork, privileged container or cluster-wide role. Apply Namespace ResourceQuota and LimitRange *only after approval*. Use app-bounded stress rather than host-wide stress.

**Candidate measurement profile (to be calibrated, not claimed observed):**
- 2 requests/s per synthetic client, fixed payload and concurrency;
- 5-minute no-fault baseline, 2-minute pre-fault steady period, up to 5 minutes of observation post-injection;
- recovery requires desired replica availability and 30 consecutive successful application probes at the specified rate;
- monitor for one additional 2-minute stable interval after recovery;
- log failures, timeouts and latency individually; record all raw data before summarizing.

Prometheus is optional for first experiments. Start with the existing Kubernetes API, Events, Pod status/restart counts and timestamped client samples. Do **not** assume the earlier Minikube Prometheus instance monitors this two-node cluster. If Prometheus is introduced, benchmark its overhead and observe sampling resolution; do not treat scrape timestamps as precise fault instants.

Use one controlled network path and validate it before trials. A port-forward or client Pod failure is not necessarily application failure; cross-check an independent signal. No internet-facing NodePort/Ingress.

## 6. Fault matrix and expected outcomes

| ID | Fault | Injection mechanism for a later approved runner | Expected native behaviour | Classification |
| --- | --- | --- | --- | --- |
| F00 | No fault | Baseline only | Healthy, stable throughput and latency | Control |
| F01 | Deployment-owned Pod terminated | Delete **one exact owned Pod UID** in synthetic namespace after allowlist validation | ReplicaSet creates replacement; brief impact possible | Auto-recovery candidate |
| F02 | Container process exits | Test-only application fault, exact named container | kubelet restarts according to restart policy; watch backoff | Auto-recovery candidate |
| F03 | Readiness becomes false | Reversible test-only flag in one app replica | Endpoint removed from Service routing; readiness recovery only when app becomes ready | Traffic isolation, not necessarily restart |
| F04 | Image cannot be pulled during an update | Apply pre-reviewed bad digest/tag **only to test Deployment**; retain old revision | Rollout stalls; prior good replicas may continue serving; no automatic rollback | Negative control |
| F05 | Bounded CPU saturation | App-local, time-limited synthetic CPU work with CPU limit | Throttling/latency changes; no guaranteed restart | Performance degradation |
| F06 | Container memory-limit breach | App-local bounded allocation in Disposable Pod; never node memory stress | OOMKilled/restart if container limit crossed; record if not | Conditional auto-recovery |
| F07 | Network delay/loss | **Deferred** until an isolated, independently verified injector is available | Measured impact depends on exact fault path; no assumption of auto repair | Advanced/deferred |

Do not inject F01–F07 until all gates pass. **Forbidden targets:** control-plane static Pods, etcd, API server, kube-system, kube-flannel, node services, host adapters, switches, disks or protected VMs. Do not drain/shutdown the only worker or change Flannel routes in this phase. No Kubernetes NetworkPolicy chaos is assumed supported by Flannel; validate CNI enforcement before any future policy experiments.

For F04, a progress-deadline event is evidence of **stalled deployment**, not evidence that Kubernetes reverted it. A human-approved rollback or fix is the separate Arm C outcome.

## 7. Evidence model and metric definitions

Write UTC wall time plus monotonic elapsed time in the independent runner. Assign one immutable run ID, source Git SHA, workload image digest, workload template hash, fault ID and pinned parameters to every sample. Check clock synchronization before a trial and report clock error; use monotonic client times for duration arithmetic.

Event timestamps:
- t0 = injection confirmed by the test runner (record command/API acknowledgement).
- t_visible = first unsuccessful or out-of-SLO synthetic request, if any.
- t_detect = first valid detection emitted by the monitored system, with detector name and confidence/evidence (never the post-hoc guessed fault time).
- t_stable = first moment that the defined availability criterion begins a successful 30-second run AND desired ready replicas are restored. Record the later completion time separately.
- t_approved, t_action and t_verified = approval, remediation execution, and verification for Arm C.

Primary measurements:

1. **Fault-to-restoration (seconds):** t_stable - t0. Also report detection-to-restoration separately; never conflate either with time-to-restart.
2. **Detection latency (seconds):** t_detect - t0, when a detection exists. No detection is a censored/failed trial, not zero.
3. **Service availability (%):** (successful / total scheduled probe requests) * 100, with exact time window; count timed-out and dropped requests as failures.
4. **HTTP response p50/p95/p99:** compute from client-side valid responses and report failure rate alongside. Report sample count and interval; do not hide errors by excluding them from availability.
5. **Throughput:** successful requests per second over a defined interval.
6. **Recovery success:** recovered within the pre-registered observation window without intervention (native) versus with intervention (gated). Both numerator and denominator required.
7. **Safety:** attempted out-of-scope actions rejected / attempted, plus false allow and false block counts across adversarial test fixtures. A zero-violation observed rate does not prove perfect safety.
8. **Operator/diagnosis:** top-1 failure-class accuracy on a labelled synthetic test set; time from t_detect to independently reviewed correct diagnosis; accuracy and unsafe suggestion rate for optional AI analysis.

Calculate mean, median, p95 and min/max of per-trial recovery durations when enough successful trials exist; report timeouts/unrecovered trials and do not drop them from the success rate. Use clearly labelled confidence intervals/bootstrap if sample size supports it. Show per-fault results and avoid an unqualified headline average across incomparable fault classes.

## 8. Pre-registration and acceptance gates

### Gate G0 — read-only platform verification (no experiment mutation)

- Resolve Git commit and private config revision; exact expected VM IDs, ownership and protected inventories.
- Confirm existing isolated Hyper-V switch, both VMs and IP/adapter mapping against the approved private contract; collect no secrets publicly.
- Read-only Stage 5 route/verification **where presently safe**, plus Stage 4 reconciliation, API readiness, 2/2 nodes Ready, CoreDNS, Flannel and authorized Pod/Service networking checks.
- Capture CPU, RAM, disk and Pod headroom; confirm target namespace is absent or approved as lab-owned.
- Confirm API access least privilege, time sync, image provenance, probe path and runner identity.
- Verify a documented independent recovery method, including versioned manifest reapply, valid image rollback and evidence preservation. Existing Hyper-V automatic checkpoints are not accepted as proof of rollback.
- Any guard failure -> **BLOCKED**, no new workload or fault.

### Gate G1 — controlled lab installation (separate approval)

- Review declarative manifests and admission/security policy; create only the allowed namespace, quota and labelled synthetic workload.
- Verify runner permissions via subject access reviews; require dry-run diff, exact resource UID/namespace and a separate approval token for mutation.
- Validate healthy stable baseline; proposed initial gates >=99.5% request success and stable Ready replicas over 5 minutes. Tune latency threshold from observed baseline rather than inventing an SLO.
- Confirm evidence export/redaction works and no resources outside scope changed.

### Gate G2 — per-fault approval and abort

- Require healthy G1 state before **each** trial, predefined exact target UID, eligible fault, time cap, and explicit human approval.
- Do not proceed when current pressure/availability deviates from baseline, trial evidence collector fails, or Pod targets are ambiguous.
- Stop fault injection if an unrelated namespace degrades, any control-plane/worker health check fails, or expected recovery fails by time cap.
- A timeout triggers **ABORT / INVESTIGATE**, not unrestricted retry or cleanup. Recovery is separately approved and idempotently verified.
- Never run two concurrent faults in Stage 1 research.

### Gate G3 — clean-state restoration

- End test-only fault flag; restore approved app manifest/image revision where appropriate; verify Deployment and Service behaviour; capture difference before/after.
- Confirm no unexpected Pod, RBAC, webhook, CRD, finalizer or host-level drift.
- Collect logs/events before resource deletion; only the precisely recorded lab-owned objects can be removed with approval.
- Record CLEAN/NOT_CLEAN/BLOCKED. Do not start the next trial without CLEAN.

## 9. Human-approved remediation protocol

Proposed deterministic sequence:

    DETECT -> COLLECT -> CLASSIFY -> PROPOSE -> POLICY_CHECK
                  -> HUMAN_APPROVAL -> APPLY_ONE_CHANGE -> VERIFY
                                           |
                                       STOP / ESCALATE

- Native Kubernetes healing is never triggered by Sentinel; its existing controllers continue to work.
- Only F04 and other explicitly labelled, persistent workload errors are candidates for change.
- Policy checks target namespace, resource owner labels and UIDs, previous known-good immutable image, exact patch diff, time bound, and rollback feasibility.
- A decision record must include input evidence hashes, proposed action, expected impact, action scope, approver, outcome and verification.
- **No autonomous LLM-authored kubectl or shell execution.** LLM suggestions are informational and may be wrong. A deterministic executor, when implemented, enforces a strict pre-reviewed action catalog.
- Stage 1 is dry-run only; Stage 2 may test an explicitly approved one-action rollback in the disposable namespace.

## 10. Proposed engineering deliverables

All proposed paths are not implemented unless separately committed and reviewed:

    docs/research/self-healing-kubernetes/
      REPLICATION-PLAN.md        <- this document, planning only
      literature-review.md       <- source comparisons / methodological differences
      experiment-register.md     <- hypotheses, run IDs, injected faults
      threat-model.md            <- targets, trust zones, attack cases
      results/README.md          <- published redacted summary only
    experiments/self-healing/
      manifests/                 <- namespace, synthetic workload, quotas
      faults/                    <- narrowly scoped fault definitions
      runner/                    <- Python CLI: plan, validate, approve, observe
      metrics/                   <- schema, collectors and reducers
      tests/                     <- policy, parser, fault selector and dry-run tests
    docs/demos/
      self-healing-demo.md        <- repeatable filmed demonstration

Execution artifact files (gitignored, not public by default):
- /private/runs/<run_id>/manifest.json with hashes, hardware capacity summary and configuration versions;
- probe-samples.jsonl (timestamp, status, latency, request ID);
- k8s-events.jsonl, pod-state.jsonl and collector-health.jsonl;
- fault-plan.json, approval.json, diff.json, recovery.json and validation.json;
- per-run metrics.json with formulas, sample counts, censoring and derived values.

Publishing process: scan for private IPs, device/MAC IDs, usernames, tokens, kubeconfigs, application payloads or confidential logs; produce synthetic or redacted examples; document redaction. Keep required raw evidence securely on the host.

## 11. Milestones and definition of done

**R0 — Protocol freeze:** references linked, hypotheses/metrics/fault classifications peer-reviewed; no VM or cluster mutation. Done when this protocol and initial safety design exist.

**R1 — Baseline workload:** independently approved synthetic app, manifest tests, load generator and read-only collector. Done when 3 dry runs show stable baseline, usable telemetry and no out-of-scope writes.

**R2 — Native self-healing trials:** F01/F02/F03, plus clean no-fault controls; all faults limited to a dedicated namespace. Done when 10 measured repeats per scenario are recorded with recovery and non-recovery labelled correctly.

**R3 — Persistent failure and resource trials:** F04/F05/F06 under the same load/metric contract. Done when stalled deployments, throttling and/or OOM outcomes are documented without assuming automatic rollback.

**R4 — Sentinel-assisted diagnosis:** connect sanitized evidence snapshots to deterministic classification and optional read-only AI investigation; human review of each diagnosis. Done with confusion matrix, unsupported suggestion count and fixed test set.

**R5 — Gated recovery:** verify negative authorization tests; optional one-action approved rollback of F04. Done when audit trail, explicit approval and complete CLEAN check are demonstrated.

**R6 — Research report and portfolio:** methods, architecture, threat model, reproducibility/limitations, 10-trial per-fault plots, case studies, video demo and career-facing summary. Done only after evidence is generated; no fabricated results.

## 12. Proposed success criteria (not measured results)

- Every executable trial correctly targets a pre-approved, isolated lab resource; zero changes to protected systems.
- Every trial has machine-parseable timing/evidence, explicit health of the measurement client, a fault-ground-truth label and a terminal recovery classification.
- At least 10 measured trials for F00–F06 as feasible, with missing data and timeout counts disclosed.
- The persistent-image failure is **not** misrepresented as native Kubernetes rollback.
- No mutation occurs through AI suggestions or without a fresh explicit approval.
- Public documentation separates academic source claims, Sentinel hypotheses and measured original results.

## 13. Suggested sequence for the next operator session

1. Read this protocol, compare against original dissertation methods, and freeze experiment IDs/metrics.
2. Execute ONLY the existing verified read-only platform inventory and health checks.
3. Capture capacity and confirm a clean, protected namespace plan (no creation yet).
4. Implement/tests for a plan-only synthetic-workload manifest generator and a dry-run evidence collector.
5. Review an exact diff and independent rollback procedure before approving any lab workload.

**No fault injection, privileged chaos controller, cluster upgrade, Hyper-V checkpoint cleanup, VM reboot, node drain, or other live mutation is authorized by this plan.**
