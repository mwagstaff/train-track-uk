import axios, { isCancel } from 'axios';
axios.defaults.timeout = 8000;

import axiosRetry from 'axios-retry';
axiosRetry(axios, {
    retries: 2,
    retryDelay: axiosRetry.exponentialDelay,
    retryCondition: (error) => axiosRetry.isNetworkOrIdempotentRequestError(error) || error?.code === 'ECONNABORTED'
});

// Fetches data from the service details API
export async function getServiceDetails(serviceId) {
    const url = `https://api1.raildata.org.uk/1010-service-details1_2/LDBWS/api/20220120/GetServiceDetails/${serviceId}`;
    try {
        const start = Date.now();
        const response = await axios.get(url, {
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

// Parse the service details response data, deleting unnecessary data to optimize the response
function parseResponseDataServiceDetails(data) {
    if (data.formation) delete data.formation;
    if (data.subsequentCallingPoints) deleteCallingPointData(data.subsequentCallingPoints);
    if (data.previousCallingPoints) deleteCallingPointData(data.previousCallingPoints);
    return data;
}

// Delete unnecesary calling point data
function deleteCallingPointData(callingPoints) {
    if (callingPoints && callingPoints.length > 0 && callingPoints[0].callingPoint && callingPoints[0].callingPoint.length > 0) {
        for (const callingPoint of callingPoints[0].callingPoint) {
            if (callingPoint.formation) {
                delete callingPoint.formation;
            }
        }
    }
}
