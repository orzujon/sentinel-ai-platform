# Day 2 four-case RAG evaluation — observed baseline

**Date:** 2026-10-24. **Source:** locally executed `day2-v1` report
from the synthetic evaluation suite. This markdown summary omits full model
outputs and request IDs; raw responses are retained locally.

## Measured results before the abstention fix

| Case | Expected / actual source | Completion | Formal warnings | HTTP client latency |
|---|---|---|---|---:|
| Kubernetes ingress 503 | RB-K8S-001 / RB-K8S-001 | stop | too_many_hypotheses | 1.472 s |
| Kubernetes CrashLoopBackOff | RB-K8S-002 / RB-K8S-002 | stop | unknown_runbook_citation, invalid_section_structure | 1.339 s |
| Cloud Foundry Gorouter 502 | RB-PCF-003 / RB-PCF-003 | stop | missing_runbook_citation, invalid_section_structure | 1.300 s |
| Unrelated office printer | no source / no source | stop | unknown_runbook_citation, too_many_hypotheses | 0.999 s |

**Retrieval accuracy@1: 4/4** for this hand-built set, including one no-match
case. **Completed generations: 4/4**. **Formal checks passed: 0/4**.
Mean sequential client latency: **1.278 s** over only four requests; not an
SLO or meaningful latency percentile.

## Human reviewer findings

### Kubernetes ingress 503

Preserved key facts, acknowledged unconfirmed hypotheses, and provided
plausible read-only inspection steps with the real `RB-K8S-001` citation.
However, it proposed three hypotheses where the task requested two. It did
not establish the actual root cause, and no claim of diagnosis is justified.

### Kubernetes CrashLoopBackOff

Correctly retrieved `RB-K8S-002`, described the known restart signals and
kept OOM as an unconfirmed hypothesis. But its "checks" included references
to `RB-K8S-001` and **nonexistent `RB-K8S-003`** as though they were the
CrashLoop runbook. It added an extra safety section and four hypotheses.
The model largely failed to translate the source into useful commands.

### Cloud Foundry Gorouter 502

Correctly retrieved `RB-PCF-003`. Suggested relevant read-only checks such
as `cf target`, `cf app`, `cf logs --recent` and route information.
However, it omitted the source citation, included an extra heading, and
offered "missing route mapping" as a hypothesis despite the incident saying
the route **is mapped**. Incorrect mapping remains possible, but that
distinction matters.

### Unrelated office printer

Retrieval correctly returned **no source**. The model nevertheless produced
printer diagnostic suggestions citing `RB-K8S-001`, `RB-K8S-002` and
nonexistent `RB-K8S-003`. These were entirely unsupported by the incident
or runbook library. This is a **boundary failure**, not just formatting.

## Corrective engineering change

The API was changed after this evaluation to **abstain deterministically
without invoking Ollama when no curated runbook matches**. This avoids
invented source claims for obvious out-of-scope inputs and avoids needless
GPU inference. No-match responses explicitly expose
`generation_status=abstained`, null model/timing fields, and
`response_checks.status=abstained`.

The mechanical validator was also corrected to flag excess hypotheses
**even when** extra/malformed headings appear. Regression tests cover both
changes.

**Caution:** Keyword retrieval can still return a false positive on
ambiguous incidents. Abstention on a zero-result lookup is not a comprehensive
out-of-scope detector, citation verification system or hallucination
prevention mechanism.

## Remaining acceptance work

1. Repeat the four cases after rebuilding the local API.
2. Confirm the unrelated case returns no source, model `null`, metrics
   `null`, `generation_status=abstained` and no invented runbook IDs.
3. Check Kubernetes CrashLoopBackOff advice against real read-only runbook
   steps and reject unknown or misattributed source citations.
4. Check PCF hypotheses acknowledge the route is already mapped.
5. Use human-reviewed factual and source-grounding judgements before
   marketing any generated response as trustworthy.
