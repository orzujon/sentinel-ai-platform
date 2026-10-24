# Sentinel AI Platform

**GPU-backed, read-only AI incident investigation lab with measured operational reliability and a curated runbook retrieval prototype.**

> **Lab only.** This project processes *synthetic* incident reports. Its local API is unauthenticated; do not expose it to the public internet or submit sensitive data. Generated recommendations are not verified diagnoses.

## Current architecture

```text
PowerShell / HTTP client (localhost:8000)
                |
           FastAPI API
          /     |      \
    /healthz  /readyz   /api/runbooks/search
                |                 |
              Ollama        Markdown runbooks
                |        (curated local corpus)
          Llama 3.2 1B
                |
           NVIDIA GPU
```

`/api/investigate` now selects the **single top runbook**, adds its bounded Markdown content to the inference prompt and returns backend-generated `sources` plus `retrieval_status`. Retrieved does **not** mean the generated diagnosis is correct or any model-produced citation has been verified.

## Verified on the local lab (2026-10-24)

- NVIDIA RTX 5060 Ti 16GB with 100% GPU-resident Ollama model.
- FastAPI health checks and 503 readiness behaviour during an Ollama outage.
- Docker Compose build and persistent external Ollama model volume.
- Synthetic `/api/investigate` requests and structured logs with request IDs.
- Cold and warm inference phases (see [benchmark report](benchmarks/2026-10-24-local-inference-baseline.md)).
- Deterministic curated runbook search independently tested without a GPU.
- GitHub Actions for API tests, Compose validation and API container build.

## Quick start (existing local lab)

Requires Docker Desktop with NVIDIA GPU support and the existing Docker volume `ai-ollama-data` containing `llama3.2:1b`.

```powershell
git clone https://github.com/orzujon/sentinel-ai-platform.git
cd sentinel-ai-platform
docker compose up -d --build
Invoke-RestMethod http://127.0.0.1:8000/healthz
Invoke-RestMethod http://127.0.0.1:8000/readyz
```

See [Compose operations](docs/compose-operations.md) for migrating old standalone containers and safeguarding the existing model volume. This is not yet a clean-machine installer.

## Runbook search (Day 2, first stage)

```powershell
$q = [uri]::EscapeDataString("Kubernetes ingress returns 503 with Ready pods")
Invoke-RestMethod "http://127.0.0.1:8000/api/runbooks/search?query=$q&top_k=2"
```

The response lists matching runbook IDs, titles, repository paths, excerpts and **relative ranking scores**. Scores are *not* confidence levels.

Curated runbooks:
- [RB-K8S-001 — Kubernetes ingress 503](knowledge/runbooks/kubernetes-ingress-503.md)
- [RB-K8S-002 — Kubernetes CrashLoopBackOff](knowledge/runbooks/kubernetes-crashloop.md)
- [RB-PCF-003 — Cloud Foundry Gorouter errors](knowledge/runbooks/cloudfoundry-router-502.md)

## RAG investigation (Day 2, second stage)

```powershell
$incident = @{
    service = "payments-api"
    environment = "staging"
    symptoms = "HTTP 503 errors increased after a deployment."
    evidence = "Three Kubernetes pods are Ready. Ingress returns 503. Application logs show upstream connection timeouts."
} | ConvertTo-Json

$r = Invoke-RestMethod -Uri "http://127.0.0.1:8000/api/investigate" -Method Post -ContentType "application/json" -Body $incident
$r.retrieval_status
$r.sources | Format-Table id, title, score
$r.analysis
$r.metrics | Format-List
```

* A matching incident should return `retrieval_status: matched` with `RB-K8S-001`.
* If nothing relevant matches, `sources` is empty and `retrieval_status` is `no_match`. The model may still make unsupported claims; human review is required.
* Source metadata comes from deterministic application retrieval, **not** the model's claims. Model-produced bracket citations are not yet independently verified.
* The three-file keyword retriever is not a vector database, a robust abstention classifier or a complete prompt-injection defence.

## Tests

```powershell
python -m pip install -r api/requirements-dev.txt
python -m pytest api/tests -q
```

Tests mock the inference API; most tests do not require Ollama or a GPU.

## Roadmap

- [x] Containerised GPU-backed inference and API
- [x] Dependency probes, API logging, basic CI and reliability exercise
- [x] Curated lexical runbook retrieval and regression tests
- [x] Inject retrieved runbooks into incident-analysis prompt with source metadata
- [ ] Evaluate generated diagnosis against labelled synthetic cases
- [ ] Authentication, permissions and prompt-injection threat modelling
- [ ] Prometheus/Grafana observability, concurrency tests and Kubernetes experiments
