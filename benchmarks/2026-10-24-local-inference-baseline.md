# Sentinel AI — GPU inference baseline (2026-10-24)

## System under test

- **Application:** Sentinel AI `POST /api/investigate` (FastAPI)
- **Model:** `llama3.2:1b`, served by Ollama via Docker Compose
- **GPU:** NVIDIA GeForce RTX 5060 Ti (16 GB VRAM)
- **Environment:** Local Windows + Docker Desktop / WSL2
- **Input:** Synthetic staging `payments-api` incident describing HTTP 503s and upstream timeouts
- **Inference residency:** Ollama `ps` showed `100% GPU`
- **Status:** Exploration baseline only, not a production benchmark

## Observed results

| Metric | Cold | Warm |
|---|---:|---:|
| Ollama total duration (s) | 2.106 | 0.630 |
| Model load duration (s) | 1.233 | 0.001 |
| Prompt evaluation (s) | 0.038 | 0.004 |
| Output generation (s) | 0.832 | 0.623 |
| Input tokens | 314 | 314 |
| Output tokens | 196 | 146 |
| Output tokens/sec | 235.52 | 234.19 |
| FastAPI request log (ms) | 2128.74 | 637.40 |
| FastAPI minus Ollama duration (ms) | 22.74 | 7.40 |

**Derivations:** Cold phases sum to 2.103 s versus 2.106 s total; warm phases sum to 0.628 s versus 0.630 s total. Differences may be rounding and additional Ollama processing overhead. Warm vs cold total-duration ratio ~3.34x, **but** output lengths differ, so this does not isolate loading benefit.

The single-sample output generation throughput stayed close to 235 tokens/s for both requests. This is not an SLO, a p95, a maximum throughput measurement, or proof of accuracy.

## Investigated anomaly

An earlier post-migration Compose request reported **27.156 s** Ollama total, **196 output tokens** and **117.56 output tokens/s**. That implies ~1.67 s of token generation and ~25.49 s of time not explained by output generation. At the time, detailed phase telemetry was unavailable, so the cause is **unknown**. Later instrumented requests did not reproduce it. Do not claim it was necessarily a cold-load, GPU, network, or scheduling issue.

## Traceability

The request and inference log lines used the same request ID:

- Cold: `bd9d8ddd-7ac7-4953-9289-96076b770721`
- Warm: `4b71b9d2-8c5f-4cc9-8d54-84dd3bc0178b`

Logs captured event type, request ID, HTTP route/status/duration, model name and Ollama timing/token counts, without intentionally logging incident text or model output. Uvicorn also emitted conventional access logs.

## What this proves

1. GPU-resident inference succeeds via the Compose-deployed Ollama service.
2. Sentinel's API successfully proxies a synthetic incident request.
3. Load, prompt evaluation and output generation timings are observable separately.
4. Request IDs correlate API and model operations.
5. Unloading the model incurs measurable cold-start work.

## What this does not prove

- Production-grade availability, security, or banking regulatory compliance.
- Multi-client scalability, sustained throughput, p95 latency, or GPU saturation.
- Correctness of AI diagnostic recommendations.
- Cause of the single 27-second outlier.

## Next experiments

- Run 10+ controlled warm repetitions with the same token generation limit and save raw results.
- Measure client-side HTTP wall-clock latency as well as Ollama durations.
- Run 2, 5 and 10 simultaneous clients; report aggregate tokens/s, error rate and p50/p95 client latency.
- Evaluate diagnostic groundedness on synthetic labelled incidents separately from infrastructure performance.
