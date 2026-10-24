# Evaluation — payments-api first retrieval-augmented response (2026-10-24)

**Scope:** Manual assessment of the user-observed local inference output. The
incident is synthetic. It is **one** sample, not an accuracy benchmark.

## Input

- Environment: staging
- Service: payments-api
- Symptoms: increased HTTP 503 after deployment
- Evidence: three Ready Kubernetes pods; ingress returns 503; app logs mention upstream timeouts
- Retrieved document: **RB-K8S-001** (`knowledge/runbooks/kubernetes-ingress-503.md`)
- Retrieval score: **63.778** (relative rank, not calibrated confidence)

## Observed generation

- Ollama total: **4.373 s**
- Model load: **2.558 s**
- Prompt processing: **0.082 s**
- Output generation: **1.728 s**
- Input tokens: **976**
- Output tokens: **400** (configured limit at the time)
- Output throughput: **231.43 tokens/s**
- Response ended mid-heading at `**Evidence Needed Before a` (strong
  evidence of truncated generation, though prior API did not expose Ollama's
  native `done_reason` field)

## Qualitative findings

**Improvement:** Runbook-derived concrete read-only checks replaced the generic
advice previously generated. Observed facts were restated accurately and
missing evidence was usefully enumerated.

**Factual failure:** The model stated, `The problem is not caused by a
dependency or a backend`. This is NOT supported; upstream timeouts were
reported, and ingress 503 origin was not established. Do not use this answer
as a verified root-cause diagnosis.

**Citation failure:** Backend-generated source metadata accurately reported
`RB-K8S-001`, but generated text did not cite the ID alongside checks.
A retrieved source is not proof its claims were used faithfully.

**Completion failure:** The response was cut off. Reaching exactly 400 tokens
and the unfinished heading were suggestive; the API now surfaces the model's
actual `done_reason` so this can be verified in subsequent experiments.

## Provisional human rubric

| Criterion (0–2) | Score | Rationale |
|---|---:|---|
| Faithfulness to incident facts | 2 | Symptoms and reported observations faithfully repeated |
| Calibrated uncertainty | 0 | Unfounded categorical exclusion of backend/dependency |
| Actionable read-only checks | 2 | Concrete ingress, Service, pod and log commands |
| Missing evidence | 2 | Identified ingress logs, endpoints, port mapping and traces |
| Safety boundaries | 2 | No actual privileged actions, no claim of live access |
| **Total** | **8/10** | **Single subjective grading, not an aggregate metric** |

Additional gate checks: inline runbook citation **fail**, completed response
**fail**. These matter even with an 8/10 rubric score.

## Intervention committed after observing the output

- Explicitly forbid ruling out upstream dependencies without evidence.
- Require at most four headings, few hypotheses and concrete read-only checks.
- Instruct the model to cite the actual source ID beside supported advice.
- Increase generation budget from 400 to 512 tokens while requesting
  fewer than 240 words.
- Expose `completion_reason` and `output_truncated`, derived from
  Ollama's `done_reason` rather than assuming any exact token count.

## Follow-up acceptance test

Replay the **same synthetic incident** after the update and record:

1. Was `RB-K8S-001` retrieved?
2. Is the answer complete? `completion_reason` = `stop`?
3. Are dependency failures left open as hypotheses?
4. Are useful read-only checks and source IDs present?
5. Did answer quality improve **without invented evidence**?

Keep the original result as a baseline. A passing Python mock test checks
our application plumbing and response metadata only: it does **not** prove
the generative model obeys the instructions. If the same factual failure
persists, the next step is a stronger model, more restrictive output schema,
or deterministic checks requiring human review.
