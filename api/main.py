"""Sentinel AI API — starting with a process-liveness check."""

from fastapi import FastAPI

app = FastAPI(title="Sentinel AI Platform", version="0.1.0")


@app.get("/healthz", tags=["operations"])
async def healthz() -> dict[str, str]:
    """Liveness: confirms the API process can handle requests.

    This does not check Ollama or the GPU. We'll add /readyz next.
    """
    return {"status": "ok", "service": "sentinel-api"}
