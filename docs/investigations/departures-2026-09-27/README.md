# East Croydon → Brighton departures investigation

Investigated 27 September 2026, approximately 01:38–01:40 BST. This is an investigation only; no application code or deployment was changed.

## Confirmed service state

| Screenshot estimate | Scheduled at East Croydon | Public service ID | Staff identity | Revised terminus | Brighton call |
| --- | --- | --- | --- | --- | --- |
| 01:53 | 26 September 23:52 | `9095985ECROYDN_` | UID `C02771`, headcode `9R69`, RID `202609266702771` | Haywards Heath | Scheduled 27 September 01:00, cancelled |
| 02:25 | 27 September 00:28 | `9121839ECROYDN_` | UID `W45509`, headcode `9W17`, RID `202609268745509` | Three Bridges | Scheduled 27 September 01:25, cancelled |

Both are Thameslink services from Bedford. Public departure estimates initially read 01:52/02:24 and advanced to the screenshot's 01:53/02:25 in the saved capture. Both staff records have an origin service date of 26 September, including the train departing East Croydon after midnight.

The Brighton-filtered public departure board returns both services with:

```json
{
  "isCancelled": false,
  "filterLocationCancelled": true,
  "futureCancellation": true
}
```

These flags are compatible: the trains still run at East Croydon, but their Brighton calls are cancelled. National Rail deliberately includes them in the filtered board with cancellation metadata. The official [LDBWS documentation](https://lite.realtime.nationalrail.co.uk/OpenLDBWS/documentation.aspx) defines `isCancelled` at the board location and `filterLocationCancelled` at the requested filter location.

The staff feed independently confirms the cancelled Brighton calls and scheduled arrival times. For 9R69, the final cancelled calls start at Wivelsfield after the last operating call at Haywards Heath. It also has earlier cancelled stops at Purley, Coulsdon South, Merstham and Redhill, followed by operating calls at Gatwick Airport, Three Bridges and Balcombe. For 9W17, the final cancelled calls start at Haywards Heath after the last operating call at Three Bridges. Neither offers a through journey to Brighton.

The public board attributes the delays to a signalling fault. The two captured service records do not supply a separate textual cancellation reason, so that delay reason should not be relabelled as a confirmed cancellation reason.

## Why the cancellation is missing in the app

`api/train-track-api/lib/realtime-trains-api.js`, `parseResponseDataLiveDepartureBoard`, selects fields from each upstream train and drops both `filterLocationCancelled` and `futureCancellation`. The public TrainTrack response therefore contains only `isCancelled: false` and the revised terminus.

`ios/TrainTrack UK/TrainTrack UK/JourneyItineraryView.swift`, `JourneyItineraryBuilder.cancellation`, detects destination cancellations from detailed calling points, then falls back to the departure's own cancellation state. With no service details and `isCancelled: false`, it returns no cancellation.

The 01:50 Southern train demonstrates the difference: its public service details successfully return the cancelled Purley-to-Brighton calls, which explains the existing partial-cancellation label in the screenshot.

Reproduction: ran the current departure parser against the captured public board and asserted, for each affected service, that the source has `filterLocationCancelled === true`, the parsed departure has `isCancelled === false`, and the parsed departure has no `filterLocationCancelled`. Both reproduced.

## Why the service map fails and keeps retrying

Repeated direct requests to the licensed public `GetServiceDetails` product for both freshly returned service IDs produced HTTP 500:

```json
{"Message":"Unable to retrieve the requested data"}
```

The corresponding TrainTrack V2 response was HTTP 200 with:

```json
[
  {"9095985ECROYDN_": {}},
  {"9121839ECROYDN_": {}}
]
```

The relevant path is:

1. `lib/service-details.js` classifies every upstream 400/500 as an unavailable service ID. The upstream message does not actually prove that these particular IDs are expired.
2. `index.js` replaces every service-detail error with `{}`, removing the unavailable/transient distinction.
3. `NetworkService.swift` skips the empty entries; `DeparturesStore.swift` returns no details and also collapses request errors into an empty result.
4. `ServiceMapView.swift`, `loadServiceDetails`, retries after 5 seconds, then 10 seconds, then every 20 seconds indefinitely for a nonhistorical service without calling points. Its generic message encourages retrying.

There is an associated-service fallback in `lib/service-details.js`, but it only runs when the context has at least two destinations. These single-destination services do not qualify. The map endpoint has no staff-feed recovery.

The staff `GetDepBoardWithDetails` product returned HTTP 200 and usable downstream calls for both trains. This establishes a recoverable difference between the public detail product and the staff board product, rather than an absence of all National Rail route data. It does not establish the internal cause of National Rail's public HTTP 500 responses or guarantee that they can never recover.

## Recommended changes

1. Preserve `filterLocationCancelled` with its destination context through the departure API and iOS model. Use it to mark the selected journey cancelled even when service details are unavailable. Preserve the distinction from cancellation of the entire train. `futureCancellation` alone is insufficient because the affected stop could be elsewhere.
2. Keep these rows visible as cancellation information, with cancellation taking precedence over delay: **Cancelled to Brighton · Terminates at Haywards Heath / Three Bridges**. Retain the original scheduled time and make clear that the train itself still runs part of the route. Do not infer cancellation simply because a train's final destination differs from the requested stop.
3. Add bounded recovery of public service-detail failures from staff data, reusing the planner's existing staff integration where appropriate. Match station, scheduled date/time, origin, operator and service identity carefully, including the previous service day across midnight. Filter out passing/operational locations and respect suppression flags. The staff query can return other services, so never take its first row as the match.
4. Preserve service-detail failure categories and cap automatic retries. A generic HTTP 500 must not be treated as proof of permanent expiration. After bounded attempts, show a stable explanation while retaining known cancellation information and a manual refresh option.

Suggested regression coverage: filtered destination cancelled while origin remains operational; cancellation metadata without details; cancellations at unrelated downstream stops; intermediate destinations and split services; these two overnight staff matches; permanent-unavailable versus transient map failures; stopping retries when the view is dismissed.

## Evidence

[`upstream-responses.json`](upstream-responses.json) contains timestamped raw public-board, public service-detail and staff-board responses. It includes only public railway data and request URLs, with no credentials. The staff requests are unfiltered by Brighton, so their own `filterLocationCancelled: false` values do not contradict the Brighton-filtered public board; their individual Brighton locations explicitly have `isCancelled: true`.
