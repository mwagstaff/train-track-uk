import axios from 'axios';
import {
    recordUpstreamApiRequest,
    recordUpstreamApiRetry,
    recordUpstreamApiRetryExhausted
} from './metrics.js';
import {
    computeExponentialBackoffMs,
    isRetryableHttpStatus,
    parseRetryAfterMs,
    retryReasonFromError,
    sleep
} from './retry-utils.js';

const DEFAULT_TIMEOUT_MS = Number(process.env.UPSTREAM_API_TIMEOUT_MS || '8000');
const DEFAULT_MAX_RETRIES = Number(process.env.UPSTREAM_API_MAX_RETRIES || '3');
const DEFAULT_RETRY_BASE_DELAY_MS = Number(process.env.UPSTREAM_API_RETRY_BASE_DELAY_MS || '300');
const DEFAULT_RETRY_MAX_DELAY_MS = Number(process.env.UPSTREAM_API_RETRY_MAX_DELAY_MS || '15000');

const client = axios.create({
    timeout: Number.isFinite(DEFAULT_TIMEOUT_MS) && DEFAULT_TIMEOUT_MS > 0 ? DEFAULT_TIMEOUT_MS : 8000
});

function shouldRetry(error) {
    const status = error?.response?.status;
    if (isRetryableHttpStatus(status)) {
        return true;
    }

    const code = error?.code;
    if (code === 'ECONNABORTED' || code === 'ETIMEDOUT' || code === 'ECONNRESET' || code === 'ENOTFOUND') {
        return true;
    }

    return !error?.response;
}

export async function getWithRetry({ api, operation, url, headers = {} }) {
    const method = 'GET';
    const retries = Number.isFinite(DEFAULT_MAX_RETRIES) && DEFAULT_MAX_RETRIES >= 0
        ? Math.trunc(DEFAULT_MAX_RETRIES)
        : 3;

    let attempt = 0;

    while (attempt <= retries) {
        const startedAt = Date.now();
        try {
            const response = await client.get(url, { headers });
            recordUpstreamApiRequest({
                api,
                operation,
                method,
                status: response?.status,
                durationMs: Date.now() - startedAt
            });
            return response;
        } catch (error) {
            const status = error?.response?.status;
            recordUpstreamApiRequest({
                api,
                operation,
                method,
                status,
                durationMs: Date.now() - startedAt
            });

            const retryable = shouldRetry(error);
            const hasAttemptsRemaining = attempt < retries;

            if (!retryable || !hasAttemptsRemaining) {
                if (retryable) {
                    recordUpstreamApiRetryExhausted({
                        api,
                        operation,
                        method,
                        reason: retryReasonFromError(error),
                        status
                    });
                }
                throw error;
            }

            const retryAfterMs = parseRetryAfterMs(error?.response?.headers?.['retry-after']);
            const backoffMs = computeExponentialBackoffMs({
                attemptNumber: attempt + 1,
                baseDelayMs: DEFAULT_RETRY_BASE_DELAY_MS,
                maxDelayMs: DEFAULT_RETRY_MAX_DELAY_MS,
                retryAfterMs
            });

            recordUpstreamApiRetry({
                api,
                operation,
                method,
                reason: retryReasonFromError(error),
                status,
                backoffMs
            });

            await sleep(backoffMs);
            attempt += 1;
        }
    }

    throw new Error('Upstream retry loop exited unexpectedly');
}
