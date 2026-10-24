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
# Capture unexpected extra standalone heading lines (e.g. Safety Boundary).
# This is only a formatting heuristic, not a semantic claim validator.
GENERIC_HEADING_PATTERN = re.compile(
    r"(?im)^\s*(?:#{1,6}\s*)?\*{0,2}"
    r"([A-Za-z][A-Za-z -]{1,60}):\*{0,2}\s*$"
)
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
    heading_like = [
        match.group(1).lower()
        for match in GENERIC_HEADING_PATTERN.finditer(analysis)
    ]
    if names != EXPECTED_HEADINGS or heading_like != EXPECTED_HEADINGS:
        warnings.append("invalid_section_structure")

    # Evaluate the hypothesis limit independently. Extra sections should not
    # hide an additional detectable violation, as the live CrashLoop case did.
    hypotheses_heading = next(
        (match for match in headings if match.group(1).lower() == "hypotheses"),
        None,
    )
    checks_heading = next(
        (
            match for match in headings
            if match.group(1).lower() == "next read-only checks"
        ),
        None,
    )
    if (
        hypotheses_heading is not None
        and checks_heading is not None
        and checks_heading.start() > hypotheses_heading.end()
    ):
        hypothesis_section = analysis[
            hypotheses_heading.end():checks_heading.start()
        ]
        if len(BULLET_PATTERN.findall(hypothesis_section)) > 2:
            warnings.append("too_many_hypotheses")

    return ResponseChecks(
        status="needs_attention" if warnings else "formal_checks_passed",
        warnings=warnings,
    )
