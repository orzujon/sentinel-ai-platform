# RB-K8S-001 — Kubernetes ingress HTTP 503 after deployment

**Platform:** Kubernetes
**Signals:** ingress 503, Service, EndpointSlice, Ready pods, upstream timeouts, new deployment
**Scope:** Synthetic lab/staging. Human-reviewed read-only diagnostics only.

## When to consult

A route returns HTTP 503 after a deployment. Some pods may still report Ready.
Distinguish ingress-to-Service errors from failures of a dependency **called
by** the application. A Ready pod does not prove an application's downstream
connections work, nor prove that the ingress is correctly targeting the pods.

## Read-only diagnostic sequence

1. Confirm **where** the 503 originates (ingress or application) and its
   timing. Review ingress controller logs or existing metrics if authorised.
2. Inspect ingress target Service and port:
   `kubectl get ingress -n staging`
   `kubectl describe ingress <name> -n staging`
3. Check Service selectors, Service ports and eligible backends:
   `kubectl get svc -n staging`
   `kubectl describe svc <name> -n staging`
   `kubectl get endpointslices -n staging -o wide`
4. Confirm pod status and the selected pods match Service labels:
   `kubectl get pods -n staging --show-labels`
   `kubectl describe pod <name> -n staging`
5. Check the application logs for request failures around the incident window:
   `kubectl logs -n staging deployment/payments-api --since=15m`
   Only use real object names and permissions appropriate to the environment.
6. Compare recent image, configuration, Service and ingress revisions using
   approved change records and read-only API queries.

## Candidate explanations — do not assert without evidence

- Ingress points at the wrong Service/port, or has no eligible backends.
- A Service selector mismatch leaves EndpointSlices without usable endpoints.
- Backend readiness differs from dependency readiness.
- The application calls a downstream dependency that is timing out.
- A recent rollout changed routing, TLS, protocol, or environment configuration.

## Evidence needed before a root-cause claim

Ingress-controller response logs, Service/EndpointSlice state, port mappings,
app request/timeout traces, downstream dependency health and a change timeline.

## Safety boundary

No rollback, deletion, restart or mutation is authorised by this runbook.
Never claim to have executed commands. Redact sensitive log data.
