#!/usr/bin/env bash
# Times journey-planner searches against a deployed API, via both the
# synchronous endpoint and the app's job flow (submit + poll).
#
#   scripts/planner-timing.sh [base-url] [date]
#   scripts/planner-timing.sh https://api.skynolimit.dev/train-track 2026-09-18
#
# Prefix with `rtk proxy` if the host needs it. Requires curl and python3.
set -euo pipefail
BASE="${1:-https://api.skynolimit.dev/train-track}/api/v3/journey-planner"
DATE="${2:-$(date +%F)}"
CLIENT="timing-$(hostname | tr -c 'A-Za-z0-9' '-')-$$"

json() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }

sync_search() {  # $1 body label, $2 body
  local t0 t1 out
  t0=$(python3 -c 'import time; print(time.time())')
  out=$(curl --silent --show-error -H 'Content-Type: application/json' -d "$2" "$BASE/search")
  t1=$(python3 -c 'import time; print(time.time())')
  printf '  sync  %-34s %6.2fs  journeys=%s  truncated=%s\n' "$1" "$(python3 -c "print($t1-$t0)")" \
    "$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("journeys",[])) if "journeys" in d else d.get("error"))')" \
    "$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("search",{}).get("searchTruncated","-"))')"
}

job_search() {  # $1 label, $2 body — mirrors the app: POST /search-jobs, poll every 1s
  local t0 t1 id status out
  t0=$(python3 -c 'import time; print(time.time())')
  out=$(curl --silent --show-error -H 'Content-Type: application/json' -H "X-Planner-Client: $CLIENT" \
        -H "Idempotency-Key: $(python3 -c 'import uuid; print(uuid.uuid4())')" -d "$2" "$BASE/search-jobs")
  id=$(echo "$out" | json id); status=$(echo "$out" | json status)
  while [ "$status" = queued ] || [ "$status" = running ]; do
    sleep 1
    out=$(curl --silent --show-error -H "X-Planner-Client: $CLIENT" "$BASE/search-jobs/$id")
    status=$(echo "$out" | json status)
  done
  t1=$(python3 -c 'import time; print(time.time())')
  printf '  job   %-34s %6.2fs  status=%s journeys=%s live=%s\n' "$1" "$(python3 -c "print($t1-$t0)")" "$status" \
    "$(echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",{}); print(len(r.get("journeys",[])))')" \
    "$(echo "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",{}); print(r.get("live",{}).get("status","-"))')"
}

body() { printf '{"origin":"%s","destination":"%s","time":"%s","timeType":"%s"%s}' "$1" "$2" "$3" "$4" "${5:-}"; }

echo "status: $(curl --silent "$BASE/status" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("available" if d.get("available") else d, "dataset", d.get("dataset",{}).get("version","")[:12], "ageDays", d.get("dataset",{}).get("ageDays"))')"
NOW=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z"))')

echo "-- scheduled only (realtime off), date $DATE: compare with the pre-change figures in docs/journey-planner-progress.md"
sync_search "KTH-VIC 07:00 depart (was 5.49s)"  "$(body KTH VIC "${DATE}T07:00:00+01:00" departAfter ',"realtime":"off"')"
sync_search "KTH-VIC 07:00 depart (repeat)"     "$(body KTH VIC "${DATE}T07:00:01+01:00" departAfter ',"realtime":"off"')"
sync_search "KTH-BTN 10:00 arrive (was 4.12s)"  "$(body KTH BTN "${DATE}T10:00:00+01:00" arriveBy ',"realtime":"off"')"
sync_search "KTH-INV 16:00 depart (was 11.51s)" "$(body KTH INV "${DATE}T16:00:00+01:00" departAfter ',"realtime":"off"')"
sync_search "KTH-INV 15:10 depart (was 13.03s)" "$(body KTH INV "${DATE}T15:10:00+01:00" departAfter ',"realtime":"off"')"
sync_search "BHM-EDB 08:00 depart"              "$(body BHM EDB "${DATE}T08:00:00+01:00" departAfter ',"realtime":"off"')"
sync_search "ECR-BNR 18:09 arrive"              "$(body ECR BNR "${DATE}T18:09:00+01:00" arriveBy ',"realtime":"off"')"

echo "-- app flow (search-jobs, realtime apply, depart now = $NOW): includes live board/detail lookups"
job_search "KTH-VIC depart now"  "$(body KTH VIC "$NOW" departAfter ',"realtime":"apply"')"
job_search "KTH-INV depart now"  "$(body KTH INV "$NOW" departAfter ',"realtime":"apply"')"
job_search "BHM-EDB depart now"  "$(body BHM EDB "$NOW" departAfter ',"realtime":"apply"')"
job_search "KTH-VIC scheduled (realtime off)" "$(body KTH VIC "${DATE}T07:00:00+01:00" departAfter ',"realtime":"off"')"
