#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${OSM_ROUTING_PYTHON:-$SCRIPT_DIR/.osm-routing-venv/bin/python}"

if [[ ! -x "$PYTHON" ]]; then
    echo "OSM routing Python environment not found at $PYTHON" >&2
    echo "Create it with: python3.12 -m venv scripts/.osm-routing-venv" >&2
    echo "Then install: scripts/.osm-routing-venv/bin/pip install -r scripts/requirements-osm-routing.txt" >&2
    exit 1
fi

exec "$PYTHON" "$SCRIPT_DIR/build_osm_railway_routing.py" "$@"
