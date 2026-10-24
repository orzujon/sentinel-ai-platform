# Day 2 — Evidence-grounded incident investigation

## Goal

Move Sentinel from a generic model with plausible text to a *retrieval-
augmented* prototype that supplies version-controlled diagnostic context.

## Design

1. A synthetic incident (service, environment, symptoms, evidence) arrives at
   FastAPI. The application validates and limits the fields.
2. The retriever searches a small curated Markdown runbook library,
   returning the most relevant documents and IDs.
3. The application adds **selected excerpts only** to the model's prompt,
   clearly marked as lower-trust reference material.
4. The model produces evidence-linked read-only recommendations.
5. The API returns separate `sources` metadata from the retrieval code.
   A listed source means **retrieved**, not independently verified or
   necessarily used correctly by the model.
6. Evaluation checks that retrieved runbooks are relevant and the generated
   answer is faithful to both incident facts and sources.

## Initial corpus

| ID | Runbook | Match signals |
|---|---|---|
| RB-K8S-001 | Kubernetes ingress 503 | ingress, Service, EndpointSlice, HTTP 503 |
| RB-K8S-002 | Kubernetes CrashLoopBackOff | restart, OOMKilled, exit code, bad configuration |
| RB-PCF-003 | Cloud Foundry router failures | Gorouter, cf route, app instance, HTTP 502/503 |

## Acceptance checks for Day 2

- Each of three synthetic case queries retrieves its matching runbook in top-1.
- Generic/unrelated incidents don't receive falsely relevant documents.
- The model receives bounded relevant text, not the entire knowledge base.
- API response includes an exact runbook ID/title/path from code, not a
  model-invented source.
- API tests validate retrieval, input handling and citations metadata.
- Human-review evaluation covers factual consistency, useful read-only steps,
  unsupported claims and source relevance.
- Existing liveness, readiness, error-handling and instrumentation tests pass.

## Explicit limitations

This is a three-runbook teaching corpus, not an enterprise knowledge system.
No embeddings, vector database, remote file ingestion or model fine-tuning
until retrieval accuracy and trust boundaries justify the complexity.
No claims about real bank incidents, current platform versions or production
access. Use synthetic lab data only.
