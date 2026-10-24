"""Validate the labelled Day 2 corpus and lexical retrieval, without Ollama.

Passing tests establish top-1 source selection on these four designed cases;
they do not establish generated-answer factual accuracy or generalisation.
"""

import json
from pathlib import Path

import pytest

from api.main import IncidentRequest
from api.retrieval import search_runbooks

DATASET = Path(__file__).resolve().parents[2] / "evaluations" / "cases" / "day2-v1.json"


def load_cases():
    return json.loads(DATASET.read_text(encoding="utf-8"))["cases"]


@pytest.mark.parametrize("case", load_cases(), ids=lambda item: item["id"])
def test_case_validation_and_expected_top_source(case):
    incident = IncidentRequest.model_validate(case["incident"])
    query = " ".join([incident.service, incident.symptoms, incident.evidence])
    hits = search_runbooks(query, top_k=1)
    actual_source = hits[0].id if hits else None

    assert actual_source == case["expected_source"]


def test_case_ids_and_review_labels_are_valid():
    cases = load_cases()
    assert len(cases) >= 4
    assert len({case["id"] for case in cases}) == len(cases)
    for case in cases:
        assert isinstance(case["review_guide"], dict)
        assert case["review_guide"]["facts_to_preserve"]
        assert case["review_guide"]["unacceptable_assertions"]
