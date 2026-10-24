"""Sentinel AI API — liveness and dependency readiness."""

import os

import httpx
from fastapi import FastAPI, HTTPException

app = FastAPI(title="Sentinel AI Platform", version="0.1.0")

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://ai-ollama:11434").rstrip("/")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.2:1b")


@app.get("/healthz", tags=["operations"])
async def healthz() -> dict[str, str]:
    """Liveness only: confirms the Sentinel API process responds."""
    return {"status": "ok", "service": "sentinel-api"}


@app.get("/readyz", tags=["operations"])
async def readyz() -> dict[str, str]:
    """Readiness: Ollama is reachable and the configured model is installed.

    This is not a GPU execution test; inference will be validated separately.
    """
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            response = await client.get(f"{OLLAMA_BASE_URL}/api/tags")
            response.raise_for_status()
            models = response.json().get("models", [])
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(
            status_code=503,
            detail="Inference service is unavailable",
        ) from exc

    installed = {
        entry.get("name", entry.get("model", ""))
        for entry in models
        if isinstance(entry, dict)
    }
    if OLLAMA_MODEL not in installed:
        raise HTTPException(
            status_code=503,
            detail="Configured inference model is not installed",
        )
    return {"status": "ready", "inference": "ollama", "model": OLLAMA_MODEL}
