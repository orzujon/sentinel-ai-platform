"""Mechanical output checks: intentionally not a hallucination detector."""

import pytest

from api.quality import check_response

BASE = """**Observed Facts:**
* HTTP 503 after deployment.
* Ingress returns 503.

**Hypotheses:**
* UNCONFIRMED: Service routing mismatch.
* UNCONFIRMED: Downstream service timeout.

**Next Read-Only Checks:**
1. Review Service endpoints. [RB-K8S-001]
2. Compare ingress target and port. [RB-K8S-001]

**Missing Evidence:**
* Ingress-controller response logs.
"""

def test_formal_checks_pass_but_human_review_is_still_required():
    result = check_response(
        BASE, source_ids=["RB-K8S-001"], completion_reason="stop"
    )
    assert result.status == "formal_checks_passed"
    assert result.warnings == []
    assert result.human_review_required is True


def test_missing_citation_flagged():
    result = check_response(
        BASE.replace("[RB-K8S-001]", ""),
        source_ids=["RB-K8S-001"],
        completion_reason="stop",
    )
    assert "missing_runbook_citation" in result.warnings


def test_invented_citation_flagged():
    result = check_response(
        BASE.replace("[RB-K8S-001]", "[RB-FAKE-999]"),
        source_ids=["RB-K8S-001"],
        completion_reason="stop",
    )
    assert "unknown_runbook_citation" in result.warnings
    assert "missing_runbook_citation" in result.warnings


@pytest.mark.parametrize("reason,warning", [
    ("length", "generation_truncated"),
    (None, "completion_unknown"),
])
def test_completion_problems_flagged(reason, warning):
    result = check_response(BASE, source_ids=["RB-K8S-001"], completion_reason=reason)
    assert warning in result.warnings


def test_three_hypotheses_flagged():
    result = check_response(
        BASE.replace(
            "* UNCONFIRMED: Downstream service timeout.",
            "* UNCONFIRMED: Downstream service timeout.\n"
            "* UNCONFIRMED: Network connectivity problem.",
        ),
        source_ids=["RB-K8S-001"],
        completion_reason="stop",
    )
    assert "too_many_hypotheses" in result.warnings


def test_extra_heading_flagged():
    result = check_response(
        BASE + "\n**Safety Boundary:**\n* No changes performed.\n",
        source_ids=["RB-K8S-001"],
        completion_reason="stop",
    )
    # Additional *unrecognised* sections are not currently detected. Formal
    # checks are intentionally narrow; this remains a human review concern.
    assert result.human_review_required is True


def test_unsupported_change_claim_requires_human_review():
    """A well-formed answer can still include a fabricated observation."""
    misleading = BASE.replace(
        "* Ingress-controller response logs.",
        "* The deployment changed TLS settings, but no timeline is supplied.",
    )
    result = check_response(
        misleading, source_ids=["RB-K8S-001"], completion_reason="stop"
    )
    assert result.status == "formal_checks_passed"
    assert result.human_review_required is True
