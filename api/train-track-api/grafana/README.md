# Grafana Dashboards

Import the JSON files in `observability/grafana/dashboards/` into Grafana for deploy-tool compatibility.

`grafana/dashboards/` contains the same dashboard JSON files as a convenience copy.

Dashboards:

- `node-runtime-health.json`
- `api-calls.json`
- `request-overview.json`
- `push-notifications.json`

Each dashboard includes:

- `datasource` variable (Prometheus datasource selector)
- `job` variable (scrape job filter)

Expected scrape endpoint for this service: `GET /metrics`.
