# Grafana Dashboards (Deploy Path)

This directory is the default location expected by `server-tooling/deploy/node_project.zsh`:

- `observability/grafana/dashboards`

Dashboard files here are used during full deploy dashboard import.

`journey-usage.json` shows current and historical scheduled, one-off, ad-hoc,
searched, and tracked journey activity, including top station endpoints.

`timetable-ingestion.json` shows hourly S3 delivery checks, last import and
activation, active source publication age (separate from S3 upload age), missing
update chains, supported coverage, compact schema 2 routing inventory, and
persisted validation/representative-day diagnostics. It uses `GET /metrics` and
the small `PLANNER_DATA_DIR/ingestion-state.json` summary, never timetable scans
or S3 requests during a scrape. Like sibling service dashboards, there are no
Prometheus/Instance/PID selectors: deployment injects the configured datasource
and queries scope the singleton `train-track-api` service. All status cards,
tables and historical gauges automatically select its newest API process at
each evaluation timestamp and collapse host/PID/scrape labels,
rather than taking the highest value from overlapping old/new processes.
Missing gauges on that process remain unavailable, not stale previous values.
The p95 histogram calculates rates per process before aggregating across PIDs,
so counter resets do not corrupt restart-spanning latency history. Unknown
values remain N/A.

The default time range is the last hour to avoid coarse seven-day sampling
missing metrics immediately after a deployment. Select a longer range for
historical comparisons. In the timestamps table, only the numeric Timestamp
column is date-formatted; Event labels remain text.

For a dashboard-only update, use Grafana **Dashboards → New → Import**, upload
`timetable-ingestion.json`, retain UID `tt-timetable-ingestion`, select the
existing folder and confirm overwrite. The deployment importer supplies the
configured Prometheus datasource; raw manual imports should use that same
datasource via Grafana's default/panel datasource settings. No API restart is
required.
A full deployment imports this project's complete dashboard directory; a quick
code-only deployment does not. Do not run the central dashboard importer with
a temporary directory containing just this file: it deletes other dashboards
in the target folder that are absent from that directory.

Freshness colours are operational indicators, not configured Grafana alerts:
bucket checks warn after 90 minutes and turn red after 3 hours; daily source and
S3 update ages warn after 36 hours and turn red after 72 hours. Publication dates
are interpreted at UTC midnight. A fresh S3 upload can contain old source data.
Supported coverage is the MCA schedule range, not a whole-network completeness
guarantee. Representative date slots are bounded to five; read their current
dates before interpreting services/operators, and inspect exclusions even when
structural validation passes.

Optional Prometheus/Grafana alert expressions (no alert rules are provisioned):

```promql
# Bucket checks overdue OR no successful check recorded while automatic ingestion is enabled.
((time() - timetable_ingestion_last_successful_check_timestamp_seconds{service_name="train-track-api"} > 5400)
 or (timetable_ingestion_enabled{service_name="train-track-api"} == 1
     unless on(service_name, instance_id, pid)
     timetable_ingestion_last_successful_check_timestamp_seconds{service_name="train-track-api"}))
and on(service_name, instance_id, pid)
(timetable_ingestion_enabled{service_name="train-track-api"} == 1)

# Missing chain: new daily deliveries cannot safely advance the active timetable.
timetable_ingestion_pending_gap_sequences{service_name="train-track-api"} > 0

# Source stale even if an old payload has just been uploaded to S3.
time() - timetable_active_publication_timestamp_seconds{service_name="train-track-api"} > 259200

# Persisted telemetry unavailable while ingestion should be running.
(timetable_ingestion_state_readable{service_name="train-track-api"} == 0)
and on(service_name, instance_id, pid)
(timetable_ingestion_enabled{service_name="train-track-api"} == 1)

# A hard-killed local worker can leave an old successful outcome behind.
timetable_ingestion_abandoned_run{service_name="train-track-api"} == 1
```

Use a pending period such as `for: 10m` for check/state alerts to allow startup,
and choose source-age thresholds appropriate to the delivered feed. An absent
publication metric does not satisfy the stale-source expression: alert on state
availability and overdue/missing successful checks as well. Successful HEAD
access still updates bucket-check freshness when imports are blocked by a gap;
that means the bucket is reachable, not that the active source is current.
A run can activate a valid compact monthly baseline and still finish with an
update-gap outcome. Automatic checks disabled does not prohibit an operator
running the manual sync command.

The enabled gauge comes from the API's current automatic-ingestion
configuration, even if a previous run persisted a different value. Worker
progress remains observational: only a stored PID on the same hostname can be
checked, and only an `ESRCH` result proves that PID has exited. Unknown/remote
owners and permission errors preserve the saved progress state. A live or
reused PID does not prove useful import progress; use check freshness and
service logs too. The dashboard's interrupted-run stat identifies a confirmed
dead local worker separately from the last completed outcome.
