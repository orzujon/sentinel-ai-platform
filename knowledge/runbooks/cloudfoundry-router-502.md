# RB-PCF-003 — Cloud Foundry route reports HTTP 502/503

**Platform:** Cloud Foundry / PCF
**Signals:** Gorouter, 502, 503, route mapping, application instances, failed upstream connection, deployment
**Scope:** Synthetic non-production foundation. Human-reviewed read-only diagnostics only.

## When to consult

A mapped route returns 502 or 503 while an app appears started or partially
healthy. Routing failures and application-side downstream failures can have
similar symptoms. A running app alone does not prove end-to-end availability.

## Read-only diagnostic sequence

1. Establish the foundation, organisation, space, route, app and exact time.
   Inspect current CLI target using `cf target`.
2. Inspect application instance health and process status:
   `cf app <app-name>`
3. Review recent app logs and events, avoiding disclosure of credentials:
   `cf logs <app-name> --recent`
   `cf events <app-name>`
4. Inspect route and app mapping with permitted read-only CLI commands:
   `cf routes`
   `cf apps`
5. Correlate available Gorouter access logs/metrics with status codes,
   backend connection errors, instance addresses and response time.
6. Compare app deployments, binding changes, route modifications and
   platform maintenance events with the incident timeline.

## Candidate explanations — do not assert without evidence

- Missing or incorrect route-to-app mapping.
- Application instance not accepting connections or crashing intermittently.
- Backend protocol, TLS or timeout mismatch.
- A downstream dependency is unavailable, generating an app-origin error.
- A deployment or platform routing change altered connectivity.

## Evidence needed before a root-cause claim

Route mapping, application instance state, recent logs/events, Gorouter
failure reason, backend connection traces, and approved change history.

## Safety boundary

Do not run `cf restart`, `cf push`, `cf map-route`, change quotas or
credentials. The runbook proposes investigation, not privileged action.
