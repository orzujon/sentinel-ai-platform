"""Deterministic, deliberately narrow output checks.

These checks validate observable response properties (completion, documented
citations and section count). They CANNOT prove factual accuracy or safety.
All LLM-generated incident recommendations require human review.
"""

from dataclasses import dataclass
import re

CITATION_PATTERN = re.compile(r"\[(RB-[A-Z0-9-]+)\]")
HEADING_PATTERN = re.compile(
    r"(?im)^\s*(?:#{1,6}\s*)?\*{0,2}"
    r"(Observed Facts|Hypotheses|Next Read-Only Checks|Missing Evidence)"
    r":\*{0,2}\s*$"
)
EXPECTED_HEADINGS = [
    "observed facts",
    "hypotheses",
    "next read-only checks",
    "missing evidence",
]
BULLET_PATTERN = re.compile(r"(?m)^\s*(?:[-*]|\d+[.)])\s+")


@dataclass(frozen=True)
class ResponseChecks:
    status: str
    warnings: list[str]
    human_review_required: bool = True


def check_response(
    analysis: str,
    *,
    source_ids: list[str],
    completion_reason: str | None,
) -> ResponseChecks:
    """Flag checkable issues without pretending to detect hallucinations."""
    warnings: list[str] = []

    if completion_reason == "length":
        warnings.append("generation_truncated")
    elif completion_reason is None:
        warnings.append("completion_unknown")

    citations = set(CITATION_PATTERN.findall(analysis))
    expected_sources = set(source_ids)
    if expected_sources and not (citations & expected_sources):
        warnings.append("missing_runbook_citation")
    if citations - expected_sources:
        warnings.append("unknown_runbook_citation")

    headings = list(HEADING_PATTERN.finditer(analysis))
    names = [item.group(1).lower() for item in headings]
    if names != EXPECTED_HEADINGS:
        warnings.append("invalid_section_structure")
    else:
        # Count only Markdown list items within the hypotheses section.
        hypothesis_section = analysis[headings[1].end():headings[2].start()]
        if len(BULLET_PATTERN.findall(hypothesis_section)) > 2:
            warnings.append("too_many_hypotheses")

    return ResponseChecks(
        status="needs_attention" if warnings else "formal_checks_passed",
        warnings=warnings,
    )
