# RB-K8S-002 — Kubernetes pod CrashLoopBackOff after configuration change

**Platform:** Kubernetes
**Signals:** CrashLoopBackOff, restart count, exit code, OOMKilled, bad config, Secret or ConfigMap, failed probe
**Scope:** Synthetic lab/staging. Human-reviewed read-only diagnostics only.

## When to consult

A workload repeatedly starts and exits after an application, environment or
configuration rollout. `CrashLoopBackOff` describes a Kubernetes container
restart backoff, not an established root cause.

## Read-only diagnostic sequence

1. Locate the affected workload and restart pattern:
   `kubectl get pods -n staging -o wide`
   `kubectl describe pod <name> -n staging`
2. Examine *last* container termination reason, exit code, OOM events, node
   pressure indicators and timestamps in the pod status/events.
3. Compare current and previous attempt logs:
   `kubectl logs <name> -n staging --previous --tail=100`
   `kubectl logs <name> -n staging --tail=100`
4. Review the deployment specification and recent rollout history:
   `kubectl describe deployment <name> -n staging`
   `kubectl rollout history deployment/<name> -n staging`
5. Verify referenced ConfigMaps and Secret **names/keys** exist through
   approved methods. Do not retrieve, reveal or print secret values.
6. Check CPU and memory requests/limits, probes, and any dependent services
   mentioned in logs.

## Candidate explanations — do not assert without evidence

- Process exits due to configuration or dependency initialisation failure.
- Container killed by OOM (confirm with termination reason; don't infer it
  from CrashLoopBackOff alone).
- Failed startup or liveness probes trigger restarts.
- Incorrect command, missing environment reference, incompatible image.

## Evidence needed before a root-cause claim

Previous container logs, pod termination reason/exit code, events,
deployment changes, resource limits and probe configuration.

## Safety boundary

Avoid restarts, edits, secret dumps, or changing production resources.
Human authorisation is required for remedial actions.
