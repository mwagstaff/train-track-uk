# Grafana Dashboards

Import the JSON files in `observability/grafana/dashboards/` into Grafana for deploy-tool compatibility.

`grafana/dashboards/` contains convenience copies of the original operational dashboards.

Dashboards:

- `node-runtime-health.json`
- `api-calls.json`
- `request-overview.json`
- `push-notifications.json`
- `journey-usage.json` (deployment directory only)
- `timetable-ingestion.json` (deployment directory only)

Each dashboard includes:

- `datasource` variable (Prometheus datasource selector)
- `job` variable (scrape job filter)

Expected scrape endpoint for this service: `GET /metrics`.
