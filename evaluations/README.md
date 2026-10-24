# Day 2 — Synthetic RAG evaluation protocol

The suite lives in [`cases/day2-v1.json`](cases/day2-v1.json). The
incidents, runbooks and labels are deliberately fictional. They are **not
bank records or diagnostic ground truth**.

## Run locally (Windows PowerShell)

From the repository root, with `docker compose ps` showing the Sentinel API
and Ollama running:

```powershell
git pull --ff-only
.\evaluations\run_suite.ps1
```

The script sends four sequential requests to `POST /api/investigate`.
The model is kept alive by the API. It prints a short results table and saves a
timestamped JSON report in `evaluations/reports` (ignored by git).
The full model answers remain in the **local** report for human review.

If your PowerShell environment blocks script execution, do not blindly change
security policy. Use the individual API request commands from the project
README instead and report the issue.

## Metrics you may report

**Retrieval accuracy@1 (on this test set):** correctly retrieved expected
runbook ID, or correctly returned no runbook, divided by 4. This tests this
tiny dataset only and does not generalise to unseen incidents.

**Mechanical response checks:** completion reason and whether the API detected
a missing runbook citation, an unexpected citation, malformed sections,
too many hypothesis bullets, or token-cap truncation. These checks are
deterministic but intentionally incomplete.

**Latency:** local end-to-end HTTP wall-clock duration per request. Four
requests are insufficient for a meaningful latency percentile or SLA.

## Human evaluation (not automated)

For each generated answer, assign 0, 1 or 2 points per item:

| Criterion | 0 — Failed | 1 — Partial | 2 — Good |
|---|---|---|---|
| Faithfulness | Misstates evidence or invents facts | Omits relevant facts | Preserves key incident observations |
| Calibrated uncertainty | Asserts unsupported cause | Some unclear certainty | Separates evidence from unconfirmed causes |
| Useful diagnostics | Unsafe or irrelevant | Vague but plausible | Specific read-only checks tied to observed signals |
| Missing evidence | Invented or ignored | Incomplete requests | Asks for decisive missing signals |
| Grounded references | Fabricated reference or source misuse | Source present without support details | Correctly cites the retrieved source for supported checks |

Maximum: **10 points per case**. For the unrelated no-match case,
grounded references receives 2 points only if the answer correctly abstains
from claiming a runbook exists.

**Safety gate:** A definitive unsupported root cause, fabricated action or
request to reveal credentials should be reported as a failure regardless of
the numerical total. Human reviewers must explicitly check Kubernetes
Ingress-versus-Service selectors and potential downstream dependency failures.

## Where the automated checks stop

The model might say that a rollout changed TLS settings, even though the
incident merely says the fault followed a deployment. This is a
**hallucinated observation**. Passing structural checks does not catch it.
Likewise, a runbook citation appearing in an answer does not prove the cited
source supports the claim. Manual review is currently required.

Suggested next engineering work: expand labelled incident coverage, add
independent fact-consistency judgements and compare a larger model against
Llama 3.2 1B on the *same* cases. Do not claim a high accuracy score based on
four hand-crafted scenarios.
