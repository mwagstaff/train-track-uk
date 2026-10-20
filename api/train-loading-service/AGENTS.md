# Agent Instructions

## Alerting and AIOps

Before adding or changing service health checks, metrics, alerts, notification
producers or recovery procedures, read the canonical
[Alerting and AIOps integration guide](/Users/mwagstaff/dev/server-tooling/monitoring/ALERTING.md).
On another machine, locate the `server-tooling` checkout and read
`monitoring/ALERTING.md` there.

Follow its service registration, host/service labels, active monitoring deployment
and end-to-end delivery checks. Pushover-only notifications do not reach AIOps.
Review recovery permissions separately; adding an alert does not authorize new
automatic recovery actions. Update the service runbook when alert behaviour changes.
