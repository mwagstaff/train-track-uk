# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Important: All Code Changes Must Be Made Locally

Always make code changes to the local files in this repository. Never edit files directly on the remote server (via SSH or otherwise) — deploys rsync from this local directory and will overwrite any server-side edits.

## Development Commands

- `npm run dev` - Start development server with hot reload (runs `./.dev.sh` which includes environment variables and nodemon)
- `npm start` - Start production server
- `npm run deploy` - Deploy to Fly.io with high availability disabled and show logs

## Architecture Overview

This is a Node.js Express API that provides train schedule data for the TrainTrack UK mobile app. The API integrates with UK Rail Data APIs to fetch real-time departure information and service details.

### Past Departures Cache

For all departures requested, the API will populate a lightweight in-memory cache that holds the following data:
 - From station
 - To station
 - Scheduled departure time
 - Estimated departure time
 - Cancellation status
 - Platform
 - Length of train
 - Service ID

This in-memory cache is used to provide past departures for the "from" and "to" stations when an API call is made to get all past departures for specific stations.

The cache is populated each time the `GET /api/v1/departures/from/:fromStation/to/:toStation` endpoint is called. Each time a request is made to this endpoint, a cache entry is either added or updated as apppropriate with the latest data for the attributes listed above.

To assist with debugging, the contents of the cache showing past journeys only can be retrieved by calling the `GET /api/v1/departures/past` endpoint.

To further assist with debugging, the entire, unfiltered contents of the cache can be retrieved by calling the `GET /api/v1/departures/past/all` endpoint.

The `GET /api/v1/departures/past/from/:fromStation/to/:toStation` endpoint can be used to retrieve all past departures for a specific "from" and "to" station. This endpoint should only return departures where the departure time is in the past.

This is so users can lookup service details and view the app service details screen for departures that have aleady left the "from" station.

The cache should only hold journeys where the departure time is 2 hours or less in the past. There should be a regular cache cleanup job that runs every hour or so to remove any expired data. It is also not designed to be persistent or survive a server restart.

### Core Structure

- **index.js** - Main Express server with API endpoints
- **lib/realtime-trains-api.js** - Handles live departure board API integration, fetches and parses train/bus departure data
- **lib/service-details.js** - Fetches detailed service information for specific train services
- **lib/xbar.js** - Generates formatted output for xbar (macOS menu bar app) with train status icons and delay information

### API Endpoints

#### V1 API (Legacy - Single requests only)

- `GET /api/v1/departures/from/:fromStation` - Get all upcoming departures from a station.
- `GET /api/v1/departures/from/:fromStation/to/:toStation` - Get all upcoming departures between specific stations.
- `GET /api/v1/departures/past/from/:fromStation/to/:toStation` - Get all past departures stored in the in-memory cache between specific stations.
- `GET /api/v1/departures/past` - Returns all past departures stored in the in-memory cache (used for debugging purposes only).
- `GET /api/v1/service_details/:serviceId` - Get detailed information for a specific service
- `GET /api/v1/xbar/from/:fromStation/to/:toStation/max_departures/:maxDepartures/return_after/:returnAfter?` - Get xbar-formatted output

**V1 Response Formats:**

`GET /api/v1/departures/from/:fromStation/to/:toStation` returns:
```json
{
    "departures": [
        {
            "departure_time": { ... },
            "operator": "...",
            ...
        }
    ]
}
```

`GET /api/v1/service_details/:serviceId` returns:
```json
{
    "previousCallingPoints": [ ... ],
    "subsequentCallingPoints": [ ... ],
    ...
}
```

#### V2 API (New - Supports multiple requests)

- `GET /api/v2/departures/from/:fromStation/to/:toStation` - Get departures for one or more journey pairs
- `GET /api/v2/departures/from/:fromStation/to/:toStation/at/:departureTime` - Get a single departure for a journey pair by `HH:mm` departure time
- `GET /api/v2/service_details/:serviceId` - Get service details for one or more services

##### Multiple Departures (V2)

`GET /api/v2/departures/from/:fromStation/to/:toStation` accepts multiple `from` and `to` pairs to return departures for multiple journeys, e.g.:
- `GET /api/v2/departures/from/:fromStation/to/:toStation/:fromStation/to/:toStation/:fromStation/to/:toStation` etc.

Example:

`GET /api/v2/departures/from/ECR/to/VIC/from/EUS/to/WFJ`

The endpoint always returns an array of departures objects with each object named `${from}_${to}`, even for a single journey:
 
```json
[
    {
        "ECR_VIC": [

        ]
    },
    {
        "EUS_WFJ": [

        ]
    }
]
```

In the above example, the first object contains the data for `ECR` to `VIC`, and the second for `EUS` to `WFJ`.

A single journey request like `GET /api/v2/departures/from/ECR/to/VIC` returns:

```json
[
    {
        "ECR_VIC": [

        ]
    }
]
```

`GET /api/v2/departures/from/:fromStation/to/:toStation/at/:departureTime` returns a single departure object for the first exact scheduled match, falling back to an exact estimated match if needed.

Example:

`GET /api/v2/departures/from/KTH/to/VIC/at/22:57`

```json
{
    "departure_time": {
        "scheduled": "22:57",
        "estimated": "22:57"
    },
    "operator": "Southeastern",
    "serviceType": "train",
    "platform": "2",
    "isCancelled": false,
    "length": 8,
    "destination": {
        "crs": "VIC",
        "locationName": "London Victoria"
    },
    "origin": {
        "crs": "ORP",
        "locationName": "Orpington"
    },
    "serviceID": "1995780KENTHOS_"
}
```

##### Multiple Services (V2)

`GET /api/v2/service_details/:serviceId` accepts multiple `serviceId` values, e.g.:
- `GET /api/v2/service_details/:serviceId/:serviceId/:serviceId`

Example:

`GET /api/v2/service_details/1729980EUSTON__/1729976EUSTON__/1729978EUSTON__`

The endpoint always returns an array of service details objects in the order the serviceId values were specified in the request, even for a single service:

```json
[
    {
        "1729980EUSTON__": {}
    },
    {
        "1729978EUSTON__": {}
    }
]
```

A single service request like `GET /api/v2/service_details/1729980EUSTON__` returns:

```json
[
    {
        "1729980EUSTON__": {}
    }
]
```

Note that if the service details for a given service isn't available (no data, error response), an empty object should be returned for that service.

##### Stations (V2)

`GET /api/v2/stations` returns the contents of `/resources/stations.json` as JSON.



### Key Dependencies

- Express.js with CORS for the web server
- Axios with retry logic for external API calls
- Moment.js for time parsing and formatting
- Lodash for data manipulation

### Environment Variables

The development script (`.dev.sh`) sets required API keys:
- `LIVE_DEPARTURE_BOARD_API_KEY` - For departure board API
- `SERVICE_DETAILS_API_KEY` - For service details API

When deploying to Fly.io, any new environment variables will need to be added, using the following command as an example:
`fly secrets set SERVICE_DETAILS_API_KEY=your-api-key`

### Data Flow

1. Client requests departures → Express route → realtime-trains-api.js
2. Makes parallel API calls to fetch current and future departures
3. Parses and deduplicates train services by serviceID
4. Returns structured JSON with departure times, delays, cancellations, and platform information

The service optimizes API calls by making parallel requests and strips unnecessary data from responses to minimize payload size.

# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
