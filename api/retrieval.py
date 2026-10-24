"""Deterministic lexical retrieval over curated, local synthetic runbooks.

No external calls, vector DB or language model. Retrieved documents are
reference material, not trusted instructions or evidence of a root cause.
"""

from collections import Counter
from dataclasses import dataclass
import math
import os
from pathlib import Path
import re

RUNBOOKS_DIR = Path(
    os.getenv(
        "KNOWLEDGE_DIR",
        str(Path(__file__).resolve().parent.parent / "knowledge" / "runbooks"),
    )
)

# Avoid rewarding grammatical words rather than infrastructure-specific signals.
STOP_WORDS = {
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could",
    "during", "for", "from", "have", "how", "in", "into", "is", "it", "my",
    "of", "on", "or", "our", "the", "there", "these", "this", "to", "was",
    "we", "were", "what", "when", "where", "which", "while", "with",
    "after", "before", "new", "an", "issue", "problem",
}

TOKEN_PATTERN = re.compile(r"[a-z0-9][a-z0-9_-]*")
HEADER_PATTERN = re.compile(r"^# (RB-[A-Z0-9-]+)\s+—\s+(.+)$", re.MULTILINE)
SIGNALS_PATTERN = re.compile(r"^\*\*Signals:\*\*\s*(.+)$", re.MULTILINE)


def tokens(text: str) -> set[str]:
    """Normalise a small, predictable English technical vocabulary."""
    words = set(TOKEN_PATTERN.findall(text.lower()))
    # Simple plural normalisation: 'endpoints' -> 'endpoint', 'pods' -> 'pod'.
    words |= {word[:-1] for word in words if word.endswith("s") and len(word) > 4}
    return words - STOP_WORDS


@dataclass(frozen=True)
class Runbook:
    id: str
    title: str
    path: str
    signals: str
    content: str


@dataclass(frozen=True)
class RunbookMatch:
    id: str
    title: str
    path: str
    score: float
    excerpt: str


def load_runbooks(directory: Path | None = None) -> list[Runbook]:
    """Read only curated markdown files from the configured local directory."""
    directory = directory or RUNBOOKS_DIR
    if not directory.is_dir():
        raise FileNotFoundError("Runbook directory is unavailable")

    runbooks: list[Runbook] = []
    for file in sorted(directory.glob("*.md")):
        # Small, curated corpus: reject unexpectedly large or malformed files.
        if file.stat().st_size > 16_384:
            raise ValueError("Runbook exceeds maximum document size")
        content = file.read_text(encoding="utf-8")
        header = HEADER_PATTERN.search(content)
        signals = SIGNALS_PATTERN.search(content)
        if not header or not signals:
            raise ValueError("Malformed runbook document")
        runbooks.append(
            Runbook(
                id=header.group(1),
                title=header.group(2).strip(),
                path=f"knowledge/runbooks/{file.name}",
                signals=signals.group(1),
                content=content,
            )
        )
    if not runbooks:
        raise FileNotFoundError("No curated runbooks are available")
    if len({r.id for r in runbooks}) != len(runbooks):
        raise ValueError("Duplicate runbook IDs")
    return runbooks


def search_runbooks(
    query: str, *, top_k: int = 2, directory: Path | None = None
) -> list[RunbookMatch]:
    """Rank documents with weighted title/signals overlap and body support.

    A match requires overlap with a title or curated Signals field; a generic
    word in document prose alone is not sufficient. Scores are relative
    ranking weights, NOT probabilities or verified relevance judgements.
    """
    if not 1 <= top_k <= 3:
        raise ValueError("top_k must be between 1 and 3")
    query_terms = tokens(query)
    if not query_terms:
        return []

    documents = load_runbooks(directory)
    indexed = [
        (
            doc,
            tokens(doc.title),
            tokens(doc.signals),
            Counter(TOKEN_PATTERN.findall(doc.content.lower())),
        )
        for doc in documents
    ]
    total = len(indexed)
    frequencies = {
        term: sum(
            term in title_terms or term in signal_terms or body_counts[term] > 0
            for _, title_terms, signal_terms, body_counts in indexed
        )
        for term in query_terms
    }
    scores: list[tuple[float, Runbook]] = []
    for doc, title_terms, signal_terms, body_counts in indexed:
        if not (query_terms & (title_terms | signal_terms)):
            continue  # do not return unrelated runbooks from generic prose
        score = 0.0
        for term in query_terms:
            df = frequencies[term]
            idf = math.log1p((total - df + 0.5) / (df + 0.5))
            score += idf * (
                5 * (term in title_terms)
                + 7 * (term in signal_terms)
                + 0.15 * min(body_counts[term], 3)
            )
        if score > 0.3:
            scores.append((score, doc))

    scores.sort(key=lambda pair: (-pair[0], pair[1].id))
    matches = []
    for score, doc in scores[:top_k]:
        # Fixed non-model excerpt, to show reviewers the source document.
        excerpt = doc.content.split("## When to consult\n", 1)[-1]
        excerpt = excerpt.split("\n##", 1)[0].strip()
        matches.append(
            RunbookMatch(
                id=doc.id,
                title=doc.title,
                path=doc.path,
                score=round(score, 3),
                excerpt=excerpt[:500],
            )
        )
    return matches
