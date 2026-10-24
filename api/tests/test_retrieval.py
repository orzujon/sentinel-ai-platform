"""The retriever is tested independently from Ollama and its language model."""

import pytest
from fastapi.testclient import TestClient

from api.main import app
from api.retrieval import load_runbooks, search_runbooks

client = TestClient(app)


@pytest.mark.parametrize(
    ("query", "expected"),
    [
        (
            "Kubernetes ingress returns HTTP 503, three Ready pods and upstream timeouts",
            "RB-K8S-001",
        ),
        (
            "Kubernetes pod CrashLoopBackOff OOMKilled restart exit code",
            "RB-K8S-002",
        ),
        (
            "Cloud Foundry PCF Gorouter 502 failed route mapping",
            "RB-PCF-003",
        ),
    ],
)
def test_expected_document_ranks_first(query, expected):
    results = search_runbooks(query, top_k=2)
    assert results
    assert results[0].id == expected
    assert results[0].score > 0
    assert results[0].path.startswith("knowledge/runbooks/")
    assert results[0].excerpt


def test_unrelated_query_does_not_retrieve_a_runbook():
    assert search_runbooks("kitten sleeping purring and grooming habits") == []


def test_metadata_is_loaded_from_documents():
    documents = load_runbooks()
    assert len(documents) == 3
    assert len({doc.id for doc in documents}) == 3


def test_api_exposes_retrieval_without_inference():
    response = client.get(
        "/api/runbooks/search",
        params={"query": "Kubernetes ingress 503 and Service endpoints", "top_k": 1},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["count"] == 1
    assert body["sources"][0]["id"] == "RB-K8S-001"
    assert "content" not in body["sources"][0]


@pytest.mark.parametrize(
    "params",
    [
        {"query": "cat"},
        {"query": "ingress routing errors", "top_k": 4},
        {"query": "x" * 401},
    ],
)
def test_search_input_is_bounded(params):
    response = client.get("/api/runbooks/search", params=params)
    assert response.status_code == 422
