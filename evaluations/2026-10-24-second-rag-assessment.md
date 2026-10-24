# Evaluation — RAG iteration 2: completed response, remaining grounding gaps

**Date:** 2026-10-24. **Data:** Synthetic staging payments incident,
same scenario as `evaluations/2026-10-24-first-rag-assessment.md`.
This is a single user-observed run, not a statistical accuracy estimate.

## Measured result

- Retrieval status: `matched`
- Source: `RB-K8S-001` (Kubernetes ingress HTTP 503 after deployment)
- Ollama `done_reason`: `stop`
- Output truncated: `false`
- Duration: **1.590 seconds**; 335 tokens generated at **223.12 tokens/s**
- Prompt tokens: 1,076; model-load: 0.001 s; prompt-eval: 0.060 s;
  output-eval: 1.501 s

## What improved

- No unsupported statement that a dependency or backend is **not** involved.
- Hypotheses explicitly labelled `UNCONFIRMED`.
- The model finished its response naturally instead of hitting the old 400
  output-token cap.
- Good general investigation areas: ingress controller logs, routing,
  Service selectors and port mapping, pod labels, change history.

## What still failed

1. **No inline runbook citation.** The application supplied the actual
   source metadata independently; the generated text did not cite it.
2. **Three hypotheses** despite the requested maximum of two.
3. **Invented evidence in missing-data section.** The statement
   `The recent rollout changed routing, TLS, protocol, or environment
   configuration` presents an unverified possibility as if it happened.
4. **Inexact fact reporting.** The observed-facts section omitted the
   provided upstream connection-timeout observation. It appeared only under
   missing evidence.
5. **Lesser technical specificity.** The model recommended relevant checks
   but omitted the precise read-only `kubectl` commands that appeared in the
   curated runbook.

## Engineering follow-up

The application now exposes a `response_checks` object with a
`needs_attention` or `formal_checks_passed` status, named warnings, and
`human_review_required=true`. Mechanical checks can detect absent source
IDs, unknown source IDs, extra/missing headings, excess hypothesis bullets,
and incomplete generation.

**Crucially, those checks CANNOT verify the truth of an incident analysis.**
They will not reliably detect the invented rollout-change claim. Source
grounding/claim validation requires separately labelled evaluations or human
review; we must not market a syntactically compliant answer as accurate.

## Next acceptance criteria

- Return `response_checks` and surface missing citations in the API.
- Confirm completion remains natural rather than token-cap truncated.
- Build additional labelled incident tests, including a contradictory and
  unrelated case, then measure human-reviewed answer quality.
- Do not deploy this unauthenticated, experimental API to the internet.
