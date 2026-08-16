import { getWithRetry } from './upstream-api-client.js';
import { testServiceHarness } from './test-service-harness.js';
import { getTrainTimes } from './realtime-trains-api.js';
import { primaryPlace } from './departure-places.js';

const SERVICE_DETAILS_TIMEOUT_MS = 3000;

// Fetches data from the service details API
export async function getServiceDetails(serviceId) {
    const testDetails = testServiceHarness.getServiceDetails(serviceId);
    if (testDetails) {
        return testDetails;
    }

    const url = `https://api1.raildata.org.uk/1010-service-details1_2/LDBWS/api/20220120/GetServiceDetails/${serviceId}`;
    try {
        const start = Date.now();
        const response = await getWithRetry({
            api: 'rail_service_details',
            operation: 'get_service_details',
            url,
            maxRetries: 0,
            timeoutMs: SERVICE_DETAILS_TIMEOUT_MS,
            headers: {
                'x-apikey': process.env.SERVICE_DETAILS_API_KEY
            }
        });
        const elapsed = Date.now() - start;
        if (elapsed > 5000) {
            console.warn(`Slow upstream: service details ${serviceId} took ${elapsed}ms`);
        }
        return parseResponseDataServiceDetails(response.data);
    } catch (error) {
        // If we got an HTTP 400 back, then log the request details and return an HTTP 400 status code
        if (error.response && error.response.status === 400) {
            const details = (() => {
                try { return JSON.stringify(error.response.data); } catch { return '[unstringifiable error data]'; }
            })();
            console.error(`No data for service ID ${serviceId}: ${details}`);
            return { error: 'No data for this service ID' };
        } else {
            const status = error?.response?.status;
            const statusText = error?.response?.statusText;
            const code = error?.code;
            const message = error?.message;
            console.error(`Failed to get data from API (code=${code || 'n/a'}, status=${status || 'n/a'} ${statusText || ''}): ${message || ''}`);
            return { error: 'Failed to get data from API' };
        }
    }
}

export async function getServiceDetailsWithContext(serviceId, context = {}) {
    const directDetails = await getServiceDetails(serviceId);
    if (hasUsableServiceDetails(directDetails)) {
        return directDetails;
    }

    const associatedDetails = await resolveAssociatedServiceDetails({
        serviceId,
        context,
        getDepartures: getTrainTimes,
        getDetails: getServiceDetails
    });
    return associatedDetails || directDetails;
}

export async function resolveAssociatedServiceDetails({
    serviceId,
    context,
    getDepartures,
    getDetails
}) {
    const toCRS = normalizeCode(context?.toCRS);
    const destinations = uniqueCodes(context?.destinationCRSs);
    const serviceIdentity = identityForServiceID(serviceId);
    if (!toCRS || destinations.length < 2 || !serviceIdentity) {
        return null;
    }

    const boards = await Promise.all(destinations.map(async (destinationCRS) => {
        const response = await getDepartures(toCRS, destinationCRS);
        return {
            destinationCRS,
            departures: Array.isArray(response?.departures) ? response.departures : []
        };
    }));
    const departures = boards.flatMap((board) => board.departures);
    const anchorCandidates = departures.filter((departure) => (
        identityForServiceID(departure?.serviceID) === serviceIdentity
            && departureMatchesContext(departure, context)
    ));

    let anchor = null;
    let anchorDetails = null;
    for (const candidate of anchorCandidates) {
        const details = await getDetails(candidate.serviceID);
        if (!details?.error) {
            anchor = candidate;
            anchorDetails = details;
            break;
        }
    }
    if (!anchor || !anchorDetails) {
        return null;
    }

    const resolved = [];
    for (const board of boards) {
        const candidates = board.departures
            .filter((departure) => departureMatchesAnchor(departure, anchor, context))
            .sort((left, right) => candidateScore(left, anchor) - candidateScore(right, anchor));

        for (const candidate of candidates) {
            if (resolved.some((item) => item.serviceID === candidate.serviceID)) {
                continue;
            }
            const details = candidate.serviceID === anchor.serviceID
                ? anchorDetails
                : await getDetails(candidate.serviceID);
            if (!details?.error) {
                resolved.push({
                    destinationCRS: board.destinationCRS,
                    serviceID: candidate.serviceID,
                    details
                });
                break;
            }
        }
    }
    if (resolved.length === 0) {
        return null;
    }

    const subsequentCallingPoints = resolved.flatMap((item) => (
        Array.isArray(item.details.subsequentCallingPoints)
            ? item.details.subsequentCallingPoints
            : []
    ));
    return {
        ...anchorDetails,
        length: normalizeLength(context?.length) || anchorDetails.length,
        destination: normalizedDestinationContext(context),
        subsequentCallingPoints,
        associatedServiceIDs: resolved.map((item) => item.serviceID)
    };
}

// Parse the service details response data, deleting unnecessary data to optimize the response
function parseResponseDataServiceDetails(data) {
    if (data.formation) delete data.formation;
    if (data.subsequentCallingPoints) deleteCallingPointData(data.subsequentCallingPoints);
    if (data.previousCallingPoints) deleteCallingPointData(data.previousCallingPoints);
    return data;
}

// Delete unnecesary calling point data
function deleteCallingPointData(callingPoints) {
    if (Array.isArray(callingPoints)) {
        for (const group of callingPoints) {
            if (!Array.isArray(group?.callingPoint)) continue;
            for (const callingPoint of group.callingPoint) {
                if (callingPoint.formation) {
                    delete callingPoint.formation;
                }
            }
        }
    }
}

function hasUsableServiceDetails(details) {
    return Boolean(
        details
            && !details.error
            && typeof details.crs === 'string'
            && details.crs.trim().length > 0
            && typeof details.locationName === 'string'
            && details.locationName.trim().length > 0
    );
}

function departureMatchesContext(departure, context) {
    const expectedOrigin = normalizeCode(context?.originCRS);
    const expectedOperator = normalizeText(context?.operator);
    const origin = normalizeCode(primaryPlace(departure?.origin)?.crs);
    const operator = normalizeText(departure?.operator);
    return (!expectedOrigin || !origin || expectedOrigin === origin)
        && (!expectedOperator || !operator || expectedOperator === operator);
}

function departureMatchesAnchor(departure, anchor, context) {
    if (!departureMatchesContext(departure, context)) {
        return false;
    }
    const anchorOrigin = normalizeCode(primaryPlace(anchor?.origin)?.crs);
    const candidateOrigin = normalizeCode(primaryPlace(departure?.origin)?.crs);
    if (anchorOrigin && candidateOrigin && anchorOrigin !== candidateOrigin) {
        return false;
    }
    const anchorOperator = normalizeText(anchor?.operator);
    const candidateOperator = normalizeText(departure?.operator);
    if (anchorOperator && candidateOperator && anchorOperator !== candidateOperator) {
        return false;
    }
    return circularTimeDifference(
        departure?.departure_time?.scheduled,
        anchor?.departure_time?.scheduled
    ) <= 15;
}

function candidateScore(candidate, anchor) {
    const identityBonus = identityForServiceID(candidate?.serviceID)
        === identityForServiceID(anchor?.serviceID) ? -100 : 0;
    return identityBonus + circularTimeDifference(
        candidate?.departure_time?.scheduled,
        anchor?.departure_time?.scheduled
    );
}

function circularTimeDifference(first, second) {
    const firstMinutes = minutesFromTime(first);
    const secondMinutes = minutesFromTime(second);
    if (firstMinutes === null || secondMinutes === null) {
        return Number.POSITIVE_INFINITY;
    }
    const difference = Math.abs(firstMinutes - secondMinutes);
    return Math.min(difference, (24 * 60) - difference);
}

function minutesFromTime(value) {
    const match = /^(\d{1,2}):(\d{2})$/.exec(String(value || '').trim());
    if (!match) return null;
    const hour = Number(match[1]);
    const minute = Number(match[2]);
    if (hour > 23 || minute > 59) return null;
    return (hour * 60) + minute;
}

function identityForServiceID(value) {
    const match = /^(\d{7})/.exec(String(value || '').trim());
    return match?.[1] || null;
}

function uniqueCodes(values) {
    return [...new Set((Array.isArray(values) ? values : [])
        .map(normalizeCode)
        .filter(Boolean))];
}

function normalizedDestinationContext(context) {
    const names = Array.isArray(context?.destinations) ? context.destinations : [];
    return uniqueCodes(context?.destinationCRSs).map((crs) => {
        const match = names.find((destination) => normalizeCode(destination?.crs) === crs);
        return {
            crs,
            locationName: match?.locationName || crs,
            via: match?.via
        };
    });
}

function normalizeLength(value) {
    const length = Number(value);
    return Number.isFinite(length) && length > 0 ? Math.round(length) : null;
}

function normalizeCode(value) {
    return typeof value === 'string' ? value.trim().toUpperCase() : '';
}

function normalizeText(value) {
    return typeof value === 'string' ? value.trim().toLowerCase() : '';
}
