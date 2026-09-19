"""Local HTTP fixtures for FutureDisruptionsUITests; start before running the tests."""
import json
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def iso(date):
    return date.isoformat().replace("+00:00", "Z")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def respond(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if not url.path.endswith("/disruptions/future"):
            return self.respond(404, {})
        stations = parse_qs(url.query).get("stations", [""])[0].split(",")
        if url.path.startswith("/unavailable/"):
            return self.respond(200, {"stations": stations, "status": "unavailable", "checkedAt": None,
                "reason": "The published engineering feed could not be checked. Try again later.", "notices": []})
        now = datetime.now(timezone.utc)
        notices = [{"id": "later", "title": "Engineering works on a later weekend", "body": "Some trains will use a different route.",
                    "kind": "engineering", "sourceURL": "https://www.nationalrail.co.uk/travel-information/",
                    "startAt": iso(now + timedelta(days=8)), "endAt": iso(now + timedelta(days=9))},
                   {"id": "earlier", "title": "Replacement buses this weekend", "body": "Buses replace trains on part of this journey. Allow extra time to travel.",
                    "kind": "engineering", "sourceURL": "https://www.nationalrail.co.uk/travel-information/",
                    "startAt": iso(now + timedelta(days=1)), "endAt": iso(now + timedelta(days=2))}]
        self.respond(200, {"stations": stations, "status": "available", "checkedAt": iso(now), "reason": None, "notices": notices})

    def do_PUT(self):
        # Automatic monitoring is intentionally shadowed while the manual browser works.
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.respond(200, {"mode": "shadow", "horizonDays": 7, "monitors": [], "advisories": []})


if __name__ == "__main__":
    print("Future disruptions UI fixture listening on 127.0.0.1:3015", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 3015), Handler).serve_forever()
