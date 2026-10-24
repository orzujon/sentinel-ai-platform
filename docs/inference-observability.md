# Sentinel observability — local inference timing

Day 1 lab. All incidents are synthetic. No auth; keep localhost-only.

## Why we added the metrics

The initial GPU inference through Compose reported approximately:
- Ollama total duration: **27.156 seconds**
- generated tokens: **196**
- generation speed: **117.56 tokens/s**

Calculated output generation time: 196 / 117.56 = ~1.667 seconds.
Unexplained by generation rate: ~25.489 seconds. This is **not**
proof of model-loading time. We need Ollama's load and prompt timings.

## Repeatable local diagnosis (PowerShell)

From the `sentinel-ai-platform` folder, make sure `docker compose ps`
shows healthy `api` and `ollama` services.

```powershell
$incident = @{
    service = "payments-api"
    environment = "staging"
    symptoms = "HTTP 503 errors increased after deployment."
    evidence = "Three pods are Ready. Ingress returns 503. Application logs show upstream connection timeouts."
} | ConvertTo-Json

# Cold: deliberately unload the model, then issue an incident request.
docker compose exec ollama ollama stop llama3.2:1b
$cold = Invoke-RestMethod -Uri "http://127.0.0.1:8000/api/investigate" -Method Post -ContentType "application/json" -Body $incident
$cold.metrics | Format-List

# Warm: same synthetic request while the model remains loaded.
$warm = Invoke-RestMethod -Uri "http://127.0.0.1:8000/api/investigate" -Method Post -ContentType "application/json" -Body $incident
$warm.metrics | Format-List

# Correlate request IDs with API timing logs.
docker compose logs api --tail 60
docker compose logs ollama --tail 60
```

## Interpreting results

- `total_seconds`: time reported by Ollama, **not** browser/client latency.
- `load_seconds`: Ollama's model loading duration; compare cold versus warm.
- `prompt_seconds`: time spent processing prompt tokens.
- `generation_seconds`: time generating output tokens.
- `tokens_per_second`: generated tokens / generation time, not whole-request throughput.
- `prompt_tokens`: number of input tokens processed.
- `X-Request-ID` HTTP header and JSON `request_id` connect API response to API log.
- `http_request.duration_ms`: whole FastAPI handling time, including calling Ollama.
- The difference between `http_request.duration_ms / 1000` and `total_seconds`
  can include connection setup, queueing, runner startup, JSON and API overhead.

Some Ollama timing fields may be unavailable and are represented as `null`.
Do not replace missing readings with invented zeros. Prompt caching, warmup,
GPU contention, and output length can change results; use repeated runs.

## Operational boundaries

- API logs never intentionally include incident `symptoms`, `evidence`,
  full model replies, auth headers, or raw untrusted path contents.
- Do not treat model readiness as proof of diagnostic accuracy.
- Ollama's own server logs and other infrastructure tooling are separate:
  review/redact them before making logs public.
- No live request monitoring dashboard has been implemented yet; this is
  structured logging and API timing instrumentation, not Prometheus/Grafana.
