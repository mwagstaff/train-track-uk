"""Deterministic HTTP fixture for the empty-window SwiftUI integration test.

Start before xcodebuild:
rtk proxy python3 'ios/TrainTrack UK/TrainTrack UKUITests/journey_planner_ui_fixture.py'

Listens only on localhost:3014. No production services or data are accessed.
"""
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from urllib.parse import urlparse, parse_qs


START = (datetime.now(timezone.utc) + timedelta(days=1)).replace(hour=9, minute=0, second=0, microsecond=0)
STATIONS = [{"crs": "KTH", "name": "Kent House", "aliases": []}, {"crs": "INV", "name": "Inverness", "aliases": []}]


def iso(value):
    return value.isoformat().replace("+00:00", "Z")


DATASET = {
    "version": "empty-window-ui-fixture", "sourceGenerationDate": START.date().isoformat(),
    "importedAt": iso(START), "coverage": {"from": f"{START.year}-01-01", "to": f"{START.year + 1}-12-31"},
    "freshness": "fresh", "scheduledOnly": True,
}


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path.endswith("/status"):
            self.respond(200, {"available": True, "apiVersion": 3, "capabilities": {"timeTypes": ["departAfter", "arriveBy"], "maxChanges": 5}, "dataset": DATASET})
        elif url.path.endswith("/stations"):
            query = parse_qs(url.query).get("q", [""])[0].upper()
            self.respond(200, {"stations": [station for station in STATIONS if query in station["crs"] or query in station["name"].upper()]})
        else:
            self.respond(404, {})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        # Fail the UI scenario if the application silently reintroduces its old cap.
        if "maxChanges" in request or ("cursor" in request and set(request) != {"cursor"}):
            self.respond(400, {"error": {"code": "INVALID_REQUEST", "message": "Expected server defaults or cursor-only paging."}})
            return
        offset = int(request.get("cursor", "window:0").split(":")[1])
        start = START + timedelta(hours=6 * offset)
        end = start + timedelta(hours=6)
        journeys = []
        if offset >= 1:
            journeys = [{"id": "fixture-later-journey", "departure": iso(start), "arrival": iso(end), "durationMinutes": 360, "changes": 3, "legs": []}]
        self.respond(200, {
            "journeys": journeys, "dataset": DATASET,
            "search": {"origin": "KTH", "destination": "INV", "time": iso(START), "timeType": "departAfter", "maxChanges": 5, "window": {"from": iso(start), "to": iso(end)}, "searchTruncated": False},
            "warnings": [], "pagination": {"earlier": f"window:{offset - 1}", "later": f"window:{offset + 1}"},
        })


if __name__ == "__main__":
    print("Planner empty-window UI fixture listening on 127.0.0.1:3014", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 3014), Handler).serve_forever()
