"""Deterministic HTTP fixture for empty-window and queued-search SwiftUI tests.

Start before xcodebuild:
rtk proxy python3 'ios/TrainTrack UK/TrainTrack UKUITests/journey_planner_ui_fixture.py'

Listens only on localhost:3014. No production services or data are accessed.
"""
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import copy
import threading
import time
import uuid
from urllib.parse import urlparse, parse_qs
from zoneinfo import ZoneInfo


START = (datetime.now(timezone.utc) + timedelta(days=1)).replace(hour=9, minute=0, second=0, microsecond=0)
LIVE_START = (datetime.now(timezone.utc) - timedelta(minutes=3)).replace(second=0, microsecond=0)
PLANNER_LIVE_START = (datetime.now(timezone.utc) + timedelta(minutes=10)).replace(second=0, microsecond=0)
STATIONS = [{"crs": "VIC", "name": "London Victoria", "aliases": []}, {"crs": "KTH", "name": "Kent House", "aliases": []}, {"crs": "INV", "name": "Inverness", "aliases": []}]
MAP_STATIONS = [{"crs": crs, "name": name, "latitude": str(latitude), "longitude": str(longitude)}
                for crs, name, latitude, longitude in [
                    ("ORP", "Orpington", 51.3735, 0.0891),
                    ("BKJ", "Beckenham Junction", 51.4112, -0.0264),
                    ("KTH", "Kent House", 51.4123, -0.0452), ("PNE", "Penge East", 51.4199, -0.0543),
                    ("VIC", "London Victoria", 51.4952, -0.1441), ("EUS", "London Euston", 51.5281, -0.1338),
                    ("STG", "Stirling", 56.1198, -3.9356), ("INV", "Inverness", 57.4802, -4.2234)]]


def detail_journey(start=START):
    places = {station["crs"]: {"crs": station["crs"], "name": station["name"]} for station in MAP_STATIONS}
    legs = []
    for kind, mode, code, origin, destination, depart, arrive in [
        ("vehicle", "rail", "SE", "KTH", "VIC", 0, 21),
        ("transfer", "tubeTransfer", None, "VIC", "EUS", 21, 60),
        ("vehicle", "rail", "LF", "EUS", "STG", 67, 422),
        ("transfer", "interchange", None, "STG", "STG", 422, 427),
        ("vehicle", "rail", "SR", "STG", "INV", 445, 630),
    ]:
        leg = {"kind": kind, "mode": mode, "operator": code, "from": places[origin], "to": places[destination],
               "departure": iso(start + timedelta(minutes=depart)), "arrival": iso(start + timedelta(minutes=arrive))}
        if origin == "KTH":
            leg["callingPoints"] = [{"station": places["PNE"], "departure": iso(start + timedelta(minutes=5))}]
            # Live details deliberately omit the full timetable route to exercise older planner responses.
            if start != LIVE_START:
                leg["serviceCallingPoints"] = [
                    {"station": places[crs], timing: iso(start + timedelta(minutes=minute))}
                    for crs, minute, timing in [("BKJ", -5, "departure"), ("KTH", 0, "departure"),
                                               ("PNE", 5, "departure"), ("VIC", 21, "arrival")]]
        if mode == "interchange":
            leg["transfer"] = {"interchangeMinutes": 5}
        if mode == "tubeTransfer":
            leg["transfer"] = {"exitMinutes": 15, "travelMinutes": 9, "entryMinutes": 15}
        legs.append(leg)
    return {"id": "fixture-details", "departure": legs[0]["departure"], "arrival": legs[-1]["arrival"],
            "durationMinutes": 630, "changes": 3, "legs": legs}


def iso(value):
    return value.isoformat().replace("+00:00", "Z")


DATASET = {
    "version": "empty-window-ui-fixture", "sourceGenerationDate": START.date().isoformat(),
    "importedAt": iso(START), "coverage": {"from": f"{START.year}-01-01", "to": f"{START.year + 1}-12-31"},
    "freshness": "fresh", "scheduledOnly": True,
}


JOBS = {}
KEYS = {}
LOCK = threading.Lock()


def search_result(request, profile=None):
    if profile == "live":
        return live_result(request.get("realtime", "apply"))
    if profile == "coverage":
        return coverage_result()
    if profile == "departures":
        return departure_rows_result()
    offset = int(request.get("cursor", "window:0").split(":")[1])
    start = START + timedelta(hours=6 * offset)
    end = start + timedelta(hours=6)
    journeys = []
    if offset >= 1:
        journeys = [{"id": "fixture-later-journey", "departure": iso(start), "arrival": iso(end), "durationMinutes": 360, "changes": 3, "legs": []}]
    if profile == "results":
        legs = [{"kind": "vehicle", "mode": "rail", "operator": code,
                 "from": STATIONS[0], "to": STATIONS[1], "departure": iso(start), "arrival": iso(end)}
                for code in ["SE", "GR", "SE", "SR"]]
        journeys = [{"id": "fixture-results", "departure": iso(start), "arrival": iso(end),
                     "durationMinutes": 360, "changes": 3, "legs": legs}]
    if profile in ["details", "live-details"]:
        journeys = [detail_journey(LIVE_START if profile == "live-details" else START)]
    return {
        "journeys": journeys, "dataset": DATASET,
        "search": {"origin": "KTH", "destination": "INV", "time": iso(START), "timeType": "departAfter", "maxChanges": 5, "window": {"from": iso(start), "to": iso(end)}, "searchTruncated": False},
        "warnings": ["Fixture search note"], "pagination": {"earlier": f"window:{offset - 1}", "later": f"window:{offset + 1}",
            **({"more": f"window:{offset + 1}"} if profile == "results" else {})},
    }


def departure_rows_result():
    result = live_result("apply")
    journeys = []
    for index, status in enumerate(["onTime", "delayed", "unknown", "cancelled"]):
        journey = copy.deepcopy(result["journeys"][0])
        scheduled = PLANNER_LIVE_START + timedelta(minutes=index * 15)
        departure = scheduled + timedelta(minutes=4 if status == "delayed" else 0)
        arrival = departure + timedelta(minutes=35)
        journey.update(id="departure-row-" + status, departure=iso(departure), arrival=iso(arrival),
                       scheduledDeparture=iso(scheduled), scheduledArrival=iso(scheduled + timedelta(minutes=35)), warnings=[])
        leg = journey["legs"][0]
        leg.update(departure=journey["departure"], arrival=journey["arrival"],
                   scheduledDeparture=journey["scheduledDeparture"], scheduledArrival=journey["scheduledArrival"],
                   callingPoints=[], warnings=[])
        leg["live"] = {"status": status, "platform": "2", "length": 10, "updatedAt": iso(datetime.now(timezone.utc)),
                       "cancelled": status == "cancelled", "partCancelled": False,
                       "departureDelayMinutes": 4 if status == "delayed" else 0,
                       "arrivalDelayMinutes": 4 if status == "delayed" else 0}
        if status != "unknown":
            leg["live"].update(departure=journey["departure"], arrival=journey["arrival"])
        journeys.append(journey)
    result.update(journeys=journeys, disruptedJourneys=[], warnings=[], pagination={})
    return result


def live_result(mode):
    scheduled_arrival = PLANNER_LIVE_START + timedelta(minutes=35)
    expected_departure = PLANNER_LIVE_START + timedelta(minutes=10)
    expected_arrival = scheduled_arrival + timedelta(minutes=10)
    checked = datetime.now(timezone.utc)
    leg = {
        "kind": "vehicle", "mode": "rail", "from": STATIONS[1], "to": STATIONS[0],
        "departure": iso(expected_departure if mode == "apply" else PLANNER_LIVE_START),
        "arrival": iso(expected_arrival if mode == "apply" else scheduled_arrival),
        "scheduledDeparture": iso(PLANNER_LIVE_START), "scheduledArrival": iso(scheduled_arrival),
        "operator": "SE", "serviceId": "fixture-service",
        "live": {"status": "delayed", "updatedAt": iso(checked), "departure": iso(expected_departure),
                 "arrival": iso(expected_arrival), "departureDelayMinutes": 10, "arrivalDelayMinutes": 10,
                 "cancelled": False, "partCancelled": True, "warnings": ["Another section of this train is cancelled."]},
        "callingPoints": [{"station": {"crs": "PNE", "name": "Penge East"},
            "departure": None if mode == "apply" else iso(PLANNER_LIVE_START + timedelta(minutes=2)),
            "scheduledDeparture": iso(PLANNER_LIVE_START + timedelta(minutes=2)),
            "live": {"status": "cancelled", "cancelled": True, "partCancelled": True,
                     "warnings": ["This stop is cancelled."]}}],
    }
    journey = {"id": "live-journey-" + mode, "departure": leg["departure"], "arrival": leg["arrival"],
               "durationMinutes": 35, "changes": 0, "legs": [leg]}
    cancelled = copy.deepcopy(journey)
    cancelled["id"] = "live-cancelled-" + mode
    cancelled["legs"][0]["live"].update(status="cancelled", cancelled=True, warnings=["This part of the train is cancelled."])
    return {
        "journeys": [journey] if mode == "apply" else [journey, cancelled],
        "disruptedJourneys": [cancelled] if mode == "apply" else [],
        "dataset": DATASET,
        "live": {"mode": mode, "status": "live", "updatedAt": iso(checked),
                 "expiresAt": iso(checked + timedelta(minutes=2)), "windowHours": 4, "warnings": []},
        "search": {"origin": "KTH", "destination": "VIC", "time": iso(PLANNER_LIVE_START), "timeType": "departAfter",
                   "realtime": mode, "maxChanges": 5,
                   "window": {"from": iso(PLANNER_LIVE_START), "to": iso(PLANNER_LIVE_START + timedelta(hours=4))}, "searchTruncated": False},
        "warnings": [], "pagination": {},
    }



def coverage_result():
    result = live_result("apply")
    journey = result["journeys"][0]
    first = journey["legs"][0]
    first["departure"] = first["scheduledDeparture"]
    first["arrival"] = first["scheduledArrival"]
    first["callingPoints"] = []
    first["live"].update(status="onTime", departure=first["departure"], arrival=first["arrival"],
                         departureDelayMinutes=0, arrivalDelayMinutes=0, partCancelled=False, warnings=[])
    generic = "This is a supplied generic transfer; detailed local departures and stops are not available."
    euston = {"crs": "EUS", "name": "London Euston"}
    inverness = {"crs": "INV", "name": "Inverness"}
    tube = {"kind": "transfer", "mode": "tubeTransfer", "from": first["to"], "to": euston,
            "departure": first["arrival"], "arrival": iso(PLANNER_LIVE_START + timedelta(minutes=65)),
            "transfer": {"exitMinutes": 5, "travelMinutes": 20, "entryMinutes": 5}, "warnings": [generic]}
    later = {"kind": "vehicle", "mode": "rail", "operator": "CS", "from": euston, "to": inverness,
             "departure": iso(PLANNER_LIVE_START + timedelta(hours=5)),
             "arrival": iso(PLANNER_LIVE_START + timedelta(hours=13))}
    journey.update(id="coverage-journey", departure=first["departure"], arrival=later["arrival"],
                   durationMinutes=780, changes=2, legs=[first, tube, later], warnings=[generic])
    result.update(disruptedJourneys=[])
    result["search"]["destination"] = "INV"
    result["live"].update(status="partial", warnings=[generic, "Later trains use scheduled times."])
    return result


def envelope(job):
    age = time.monotonic() - job["created"]
    if job["cancelled"]:
        status = "cancelled"
    elif job["profile"] == "cancel":
        status = "queued" if age < 5 else "running"
    elif job["profile"] == "queued":
        status = "queued" if age < 5 else "running" if age < 10 or "cursor" in job["request"] else "completed"
    elif job["profile"] == "results" and "cursor" in job["request"]:
        status = "running"
    else:
        status = "completed"
    value = {"id": job["id"], "status": status, "pollAfterMs": 500}
    if status == "queued":
        value["queuePosition"] = 1
    if status == "completed":
        value["result"] = search_result(job["request"], job["profile"])
    return value


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
        if "/journeys/departure-row-" in url.path:
            journey_id = url.path.rsplit("/", 1)[-1]
            result = departure_rows_result()
            journey = next((value for value in result["journeys"] if value["id"] == journey_id), None)
            self.respond(200, {"journey": journey, "dataset": DATASET, "live": result["live"]}) if journey else self.respond(404, {})
        elif url.path.endswith("/journeys/coverage-journey"):
            result = coverage_result()
            self.respond(200, {"journey": result["journeys"][0], "dataset": DATASET, "live": result["live"]})
        elif "/journeys/live-" in url.path:
            journey_id = url.path.rsplit("/", 1)[-1]
            mode = journey_id.rsplit("-", 1)[-1]
            result = live_result(mode)
            candidates = result["journeys"] + result["disruptedJourneys"]
            journey = next((value for value in candidates if value["id"] == journey_id), None)
            self.respond(200, {"journey": journey, "dataset": DATASET, "live": result["live"]}) if journey else self.respond(404, {})
        elif "/search-jobs/" in url.path:
            with LOCK:
                job = JOBS.get(url.path.rsplit("/", 1)[-1])
                self.respond(200, envelope(job)) if job else self.respond(410, {})
        elif url.path.endswith("/test-state"):
            profile = url.path.split("/")[1]
            with LOCK:
                self.respond(200, {"cancelled": sum(job["cancelled"] for job in JOBS.values() if job["profile"] == profile)})
        elif url.path.endswith("/journeys/fixture-details"):
            self.respond(200, {"journey": detail_journey(LIVE_START if url.path.startswith("/live-details/") else START), "dataset": DATASET})
        elif url.path.startswith("/live-details/") and "/departures/from/" in url.path:
            scheduled = LIVE_START.astimezone(ZoneInfo("Europe/London")).strftime("%H:%M")
            self.respond(200, {"KTH_VIC": {"departures": [{"serviceID": "fixture-live", "serviceType": "train",
                "operatorCode": "SE", "timestamp": iso(datetime.now(timezone.utc)),
                "departure_time": {"scheduled": scheduled, "estimated": "On time", "actual": scheduled}}],
                "data_status": "live"}})
        elif url.path.endswith("/service_details/fixture-live"):
            def call(crs, name, minutes, actual=False):
                timing = (LIVE_START + timedelta(minutes=minutes)).astimezone(ZoneInfo("Europe/London")).strftime("%H:%M")
                actual = actual or (crs == "PNE" and datetime.now(timezone.utc) > LIVE_START + timedelta(minutes=minutes, seconds=30))
                return {"crs": crs, "locationName": name, "st": timing, "et": "On time", "at": timing if actual else None}
            self.respond(200, [{"fixture-live": {"generatedAt": iso(datetime.now(timezone.utc)), "serviceType": "train",
                "operatorCode": "SE", "operator": "Southeastern", "crs": "KTH", "locationName": "Kent House",
                "std": call("KTH", "Kent House", 0)["st"], "etd": "On time", "atd": call("KTH", "Kent House", 0)["st"],
                "previousCallingPoints": [{"callingPoint": [call("ORP", "Orpington", -20, True), call("BKJ", "Beckenham Junction", -5, True)]}],
                "subsequentCallingPoints": [{"callingPoint": [call("PNE", "Penge East", 5), call("VIC", "London Victoria", 21)]}]}}])
        elif url.path.endswith("/config"):
            self.respond(200, {"operator_branding": {"version": "fixture", "operators": [
                {"name": name, "operator_codes": [code], "aliases": [], "color_hex": color}
                for name, code, color in [("Southeastern", "SE", "#1B2254"), ("LNER", "GR", "#E5007D"), ("ScotRail", "SR", "#FFFFFF")]
            ]}})
        elif url.path.endswith("/status"):
            self.respond(200, {"available": True, "apiVersion": 3, "capabilities": {"timeTypes": ["departAfter", "arriveBy"], "maxChanges": 5}, "dataset": DATASET})
        elif url.path.endswith("/api/v2/stations"):
            self.respond(200, MAP_STATIONS)
        elif url.path.endswith("/stations"):
            query = parse_qs(url.query).get("q", [""])[0].upper()
            self.respond(200, {"stations": [station for station in STATIONS if query in station["crs"] or query in station["name"].upper()]})
        else:
            self.respond(404, {})

    def do_POST(self):
        path = urlparse(self.path).path
        if not path.endswith(("/search", "/search-jobs")):
            self.respond(404, {})
            return
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        # Fail if the app reintroduces its old cap or sends extra paging fields.
        if "maxChanges" in request or ("cursor" in request and set(request) != {"cursor"}):
            self.respond(400, {"error": {"code": "INVALID_REQUEST", "message": "Expected server defaults or cursor-only paging."}})
            return
        if path.endswith("/search"):
            self.respond(200, search_result(request))
            return
        key = self.headers.get("Idempotency-Key")
        client = self.headers.get("X-Planner-Client")
        if not key or not client:
            self.respond(400, {"error": {"code": "INVALID_REQUEST", "message": "Job identity headers are required."}})
            return
        with LOCK:
            identity = (client, key)
            if identity not in KEYS:
                job_id = str(uuid.uuid4())
                KEYS[identity] = job_id
                JOBS[job_id] = {"id": job_id, "profile": path.split("/")[1], "created": time.monotonic(), "request": request, "cancelled": False}
            self.respond(202, envelope(JOBS[KEYS[identity]]))

    def do_DELETE(self):
        with LOCK:
            job = JOBS.get(urlparse(self.path).path.rsplit("/", 1)[-1])
            if job:
                job["cancelled"] = True
        self.send_response(204)
        self.end_headers()


if __name__ == "__main__":
    print("Planner UI fixture listening on 127.0.0.1:3014", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 3014), Handler).serve_forever()
