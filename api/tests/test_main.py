"""Deterministic Sentinel API tests: no GPU, model or network required."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from api import main

client = TestClient(main.app)

INCIDENT = {
    "service": "payments-api",
    "environment": "staging",
    "symptoms": "HTTP 503 errors increased after deployment.",
    "evidence": "Pods are Ready; application logs show upstream timeouts.",
}


def mock_ollama(monkeypatch, handler):
    """Replace outbound HTTP with a controlled in-memory mock transport."""
    original_client = httpx.AsyncClient

    def make_client(**kwargs):
        return original_client(transport=httpx.MockTransport(handler), **kwargs)

    monkeypatch.setattr(main.httpx, "AsyncClient", make_client)


def test_health_is_independent_of_inference():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "service": "sentinel-api"}
    assert response.headers["X-Request-ID"]


def test_ready_when_model_is_installed(monkeypatch):
    def handler(request):
        assert request.url.path == "/api/tags"
        return httpx.Response(200, json={"models": [{"name": "llama3.2:1b"}]})

    mock_ollama(monkeypatch, handler)
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"


def test_not_ready_if_model_is_missing(monkeypatch):
    mock_ollama(
        monkeypatch,
        lambda request: httpx.Response(200, json={"models": []}),
    )
    response = client.get("/readyz")
    assert response.status_code == 503
    assert "not installed" in response.json()["detail"]


def test_not_ready_if_ollama_is_offline(monkeypatch):
    def handler(request):
        raise httpx.ConnectError("offline", request=request)

    mock_ollama(monkeypatch, handler)
    response = client.get("/readyz")
    assert response.status_code == 503


def test_investigate_uses_model_and_returns_metrics(monkeypatch):
    def handler(request):
        assert request.url.path == "/api/generate"
        payload = json.loads(request.content)
        assert payload["model"] == "llama3.2:1b"
        assert "payments-api" in payload["prompt"]
        assert "RB-K8S-001" in payload["prompt"]
        assert "kubectl get endpointslices" in payload["prompt"]
        assert "RB-PCF-003" not in payload["prompt"]
        assert "not as instructions" in payload["system"].lower() or "never as instructions" in payload["system"].lower()
        assert payload["stream"] is False
        assert payload["options"]["num_predict"] == 512
        assert "A pod being Ready does not rule out" in payload["system"]
        assert "at most 4 concrete" in payload["system"]
        return httpx.Response(
            200,
            json={
                "response": "Observed facts: Ingress returned 503. Hypotheses: routing issue (unconfirmed).",
                "total_duration": 1_250_000_000,
                "eval_count": 100,
                "eval_duration": 1_000_000_000,
                "load_duration": 100_000_000,
                "prompt_eval_duration": 150_000_000,
                "prompt_eval_count": 27,
                "done_reason": "stop",
            },
        )

    mock_ollama(monkeypatch, handler)
    response = client.post("/api/investigate", json=INCIDENT)
    assert response.status_code == 200
    body = response.json()
    assert body["advisory_only"] is True
    assert body["model"] == "llama3.2:1b"
    assert body["metrics"]["generated_tokens"] == 100
    assert body["metrics"]["tokens_per_second"] == 100.0
    assert body["metrics"]["total_seconds"] == 1.25
    assert body["metrics"]["load_seconds"] == 0.1
    assert body["metrics"]["prompt_seconds"] == 0.15
    assert body["metrics"]["generation_seconds"] == 1.0
    assert body["metrics"]["prompt_tokens"] == 27
    assert body["request_id"] == response.headers["X-Request-ID"]
    assert body["completion_reason"] == "stop"
    assert body["output_truncated"] is False
    assert body["retrieval_status"] == "matched"
    assert len(body["sources"]) == 1
    assert body["sources"][0]["id"] == "RB-K8S-001"
    assert body["sources"][0]["path"] == (
        "knowledge/runbooks/kubernetes-ingress-503.md"
    )


@pytest.mark.parametrize(
    "overrides",
    [
        {"environment": "production"},
        {"symptoms": "short"},
        {"unknown_property": "do-not-accept"},
    ],
)
def test_invalid_incident_is_rejected(overrides):
    response = client.post("/api/investigate", json={**INCIDENT, **overrides})
    assert response.status_code == 422


@pytest.mark.parametrize(
    ("kind", "expected_status"),
    [
        ("unavailable", 503),
        ("timeout", 504),
        ("upstream_error", 502),
    ],
)
def test_inference_failures_are_not_success(monkeypatch, kind, expected_status):
    def handler(request):
        if kind == "unavailable":
            raise httpx.ConnectError("offline", request=request)
        if kind == "timeout":
            raise httpx.ReadTimeout("slow model", request=request)
        return httpx.Response(500, json={"error": "model crashed"})

    mock_ollama(monkeypatch, handler)
    response = client.post("/api/investigate", json=INCIDENT)
    assert response.status_code == expected_status
    assert response.json()["detail"]


def test_unrelated_incident_does_not_claim_a_source(monkeypatch):
    unrelated = {
        "service": "kitten",
        "environment": "lab",
        "symptoms": "Purring, grooming and sleeping after feeding.",
        "evidence": "No infrastructure symptoms are reported.",
    }

    def handler(request):
        payload = json.loads(request.content)
        assert "NO MATCHING CURATED RUNBOOK" in payload["prompt"]
        assert "RB-K8S-001" not in payload["prompt"]
        return httpx.Response(
            200,
            json={
                "response": "Evidence is insufficient for an infrastructure diagnosis.",
                "total_duration": 1_000_000_000,
                "eval_count": 10,
                "eval_duration": 100_000_000,
            },
        )

    mock_ollama(monkeypatch, handler)
    response = client.post("/api/investigate", json=unrelated)
    assert response.status_code == 200
    assert response.json()["retrieval_status"] == "no_match"
    assert response.json()["sources"] == []


def test_retrieval_unavailable_does_not_call_model(monkeypatch):
    def offline(query_text, *, top_k):
        raise FileNotFoundError("simulated missing runbook directory")

    monkeypatch.setattr(main, "search_runbooks", offline)
    response = client.post("/api/investigate", json=INCIDENT)
    assert response.status_code == 503
    assert "Curated runbook library" in response.json()["detail"]


@pytest.mark.parametrize(
    ("done_reason", "expected_truncated"),
    [
        ("length", True),
        ("stop", False),
        (None, None),
    ],
)
def test_inference_reports_completion_reason(
    monkeypatch, done_reason, expected_truncated
):
    def handler(request):
        model_data = {
            "response": "Synthetic generated advice.",
            "total_duration": 100_000_000,
            "eval_count": 5,
            "eval_duration": 30_000_000,
        }
        if done_reason is not None:
            model_data["done_reason"] = done_reason
        return httpx.Response(200, json=model_data)

    mock_ollama(monkeypatch, handler)
    response = client.post("/api/investigate", json=INCIDENT)
    assert response.status_code == 200
    body = response.json()
    assert body["completion_reason"] == done_reason
    assert body["output_truncated"] is expected_truncated
