# Sentinel AI Platform — engineering case study

**Domain:** AI incident investigation + reproducible Kubernetes infrastructure  
**Environment:** independent, local homelab with synthetic incidents  
**Maturity:** working prototypes and verified lab stages; **not** a production AI platform

[Source repository](../README.md) · [Inference benchmark](../benchmarks/2026-10-24-local-inference-baseline.md) · [RAG evaluation](../evaluations/2026-10-24-four-case-baseline.md) · [Infrastructure provisioning](../infrastructure/level1/README.md)

## Problem and engineering goal

Platform incidents bring together application symptoms, networking, deployment changes and runbooks. A language model can suggest checks, but it can also invent citations or confidently explain the wrong problem. At the same time, lab infrastructure must be reproducible without exposing secrets, adopting unknown VMs or concealing destructive actions.

I split the work into **two tracks**: a locally served incident-analysis API, and a guarded Kubernetes infrastructure automation lab. They are **not yet an integrated Kubernetes-hosted AI service**.

## System design

```text
TRACK A — LOCAL INFERENCE AND INCIDENT ANALYSIS

Synthetic incident (HTTP POST)
           |
           v
       FastAPI API -------- /healthz and /readyz
           |
     curated runbook search ----> Markdown corpus (3 runbooks)
           |
    bounded retrieved context
           |
           v
    Ollama / Llama 3.2 1B ----> NVIDIA GPU
           |
           v
 Structured response + source metadata + mechanical checks
           |
           v
   Human review required; no automatic remediation


TRACK B — KUBERNETES INFRASTRUCTURE LAB

Windows management host (PowerShell controller)
           |
     preflight, ownership checks, approvals, run evidence
           |
         Hyper-V
           |
   isolated Ubuntu control-plane + worker VMs
           |
      trusted SSH / Ansible
           |
   containerd / kubeadm / Flannel / CoreDNS
           |
    cluster, DNS and cross-node network validation
```

## Decisions and trade-offs

| Decision | Why it matters | Boundary |
| --- | --- | --- |
| **Local GPU inference** with Ollama | Explore inference operations and latency without requiring an external hosted model for synthetic incidents | One local model and GPU; not evidence of scalable serving |
| **Small curated lexical retriever** | Simple to inspect, test and correlate with known runbooks | Keyword false positives remain possible; not vector RAG |
| **Application-owned source metadata** | Source IDs should not depend on the model inventing citations | Correct retrieval does not guarantee correct advice |
| **Deterministic no-match abstention** | Avoid invoking the model when no curated source matches | No protection against all ambiguous or malicious inputs |
| **Mandatory human review** | Mechanical output checks cannot prove diagnosis accuracy | No autonomous incident response |
| **Read-only infrastructure plans, explicit apply gates** | Separate discovery from mutation and protect existing VMs | No transactional rollback or finished clean-room installer |
| **Private runtime configuration, ignored evidence** | Keep secrets and actual host details out of public source control | Secrets-store integration is proposed, not delivered |

## Evidence: what was actually measured

### GPU / API experiment (2026-10-24)

The [published single-request baseline](../benchmarks/2026-10-24-local-inference-baseline.md) records the following on an RTX 5060 Ti 16 GB GPU, with Ollama serving `llama3.2:1b`:

| Metric | Cold request | Warm request |
| --- | ---: | ---: |
| Ollama total duration | 2.106 s | 0.630 s |
| Generated output tokens | 196 | 146 |
| Generation throughput | 235.52 tokens/s | 234.19 tokens/s |

These are **individual local observations**, not p95 latency, sustained concurrency throughput, a production SLO or proof of model quality. Output lengths differed, so the cold/warm difference does not isolate the model-load effect.

### A failure that changed the design

A [four-incident synthetic evaluation](../evaluations/2026-10-24-four-case-baseline.md) selected the expected top runbook in **4/4 hand-built cases**, but **0/4 generated answers passed all formal output checks**. One out-of-scope printer incident triggered unsupported runbook citations.

Instead of advertising retrieval accuracy as diagnostic accuracy, I introduced **deterministic abstention when retrieval returns no match** and strengthened mechanical response checks. This is a narrow mitigation, not a general hallucination guardrail. The published report explicitly asks for further post-fix and human-reviewed evaluation.

### Kubernetes lab validation

The source includes [read-only/approval-gated Ansible workflows](../infrastructure/ansible/), [cluster validation](../infrastructure/ansible/playbooks/140-cluster-validate.yml) and [active DNS/network checks](../infrastructure/ansible/playbooks/150-active-network.yml). In the local lab, I exercised a two-node control-plane/worker configuration and checked node readiness, Flannel, DNS, cross-node Pod traffic and Service routing.

The **local acceptance observations are not an independently verifiable production deployment report**. The existing [Level 1 README](../infrastructure/level1/README.md) records the present bootstrap limitations. Reproducible, clean-machine orchestration and a published redacted validation report are still outstanding.

## How I would take this further

1. **Trust:** authenticated APIs, scoped access controls, threat modelling, prompt-injection tests and verifiable source-grounding metrics.
2. **Operational quality:** repeated latency/concurrency runs, percentiles and error rates; Prometheus/Grafana or OpenTelemetry metrics; alerting and incident drills.
3. **Delivery:** clean-room reproducible build, a declared configuration/secret boundary, CI gates, and deployment of the AI service onto a validated Kubernetes environment.

## What I deliberately do not claim

- No production traffic, customer incidents or enterprise compliance certification.
- No autonomous remediation, demonstrated model accuracy or reliable citation verification.
- No high-availability cluster, GPU autoscaling, deployment SLO or end-to-end self-service installer.
- No employer confidential data or source code in this public lab.

**The engineering objective is to make failure states observable, changes reviewable and claims traceable to evidence—not to make a prototype appear more mature than it is.**
