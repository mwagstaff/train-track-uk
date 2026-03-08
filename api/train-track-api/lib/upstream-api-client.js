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
const DEFAULT_RETRY_BASE_DELAY_MS = Number(process.env.UPSTREAM_API_RETRY_BASE_DELAY_MS || '2000');
const DEFAULT_RETRY_MAX_DELAY_MS = Number(process.env.UPSTREAM_API_RETRY_MAX_DELAY_MS || '15000');
const DEFAULT_RATE_LIMIT_DELAY_FLOOR_MS = Number(process.env.UPSTREAM_API_MIN_429_DELAY_MS || '2000');
const DEFAULT_GLOBAL_REQUEST_SPACING_MS = Number(process.env.UPSTREAM_API_MIN_REQUEST_SPACING_MS || '0');
const DEFAULT_RAILDATA_REQUEST_SPACING_MS = Number(process.env.RAILDATA_API_MIN_REQUEST_SPACING_MS || '100');

const hostNextRequestAtMs = new Map();
const hostSpacingTails = new Map();

const client = axios.create({
    timeout: Number.isFinite(DEFAULT_TIMEOUT_MS) && DEFAULT_TIMEOUT_MS > 0 ? DEFAULT_TIMEOUT_MS : 8000
});

function logUpstreamRateLimit({
    api,
    operation,
    method,
    url,
    status,
    attempt,
    maxRetries,
    maxAttempts,
    retryAfterMs,
    backoffMs,
    code,
    message
}) {
    console.warn(JSON.stringify({
        event: 'upstream_api_rate_limited',
        timestamp: new Date().toISOString(),
        api,
        operation,
        method,
        url,
        status,
        attempt,
        maxRetries,
        maxAttempts,
        retryAfterMs: Number.isFinite(retryAfterMs) ? retryAfterMs : null,
        backoffMs: Number.isFinite(backoffMs) ? backoffMs : null,
        code: code || null,
        message: message || null
    }));
}

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

function normalizeSpacingMs(value, fallback = 0) {
    const numericValue = Number(value);
    if (!Number.isFinite(numericValue) || numericValue < 0) {
        return fallback;
    }
    return Math.trunc(numericValue);
}

function getRequestSpacingMsForUrl(url) {
    try {
        const hostname = new URL(url).hostname.toLowerCase();
        if (hostname === 'api1.raildata.org.uk') {
            return normalizeSpacingMs(DEFAULT_RAILDATA_REQUEST_SPACING_MS, 100);
        }
    } catch {
        // Fall back to the global spacing value when URL parsing fails.
    }

    return normalizeSpacingMs(DEFAULT_GLOBAL_REQUEST_SPACING_MS, 0);
}

async function waitForRequestSpacing(url) {
    const spacingMs = getRequestSpacingMsForUrl(url);
    if (spacingMs <= 0) {
        return;
    }

    let hostname = 'global';
    try {
        hostname = new URL(url).hostname.toLowerCase() || 'global';
    } catch {
        // Use the global queue key when URL parsing fails.
    }

    const previousTail = hostSpacingTails.get(hostname) || Promise.resolve();
    let releaseCurrentTail;
    const currentTail = new Promise((resolve) => {
        releaseCurrentTail = resolve;
    });

    hostSpacingTails.set(hostname, previousTail.catch(() => {}).then(() => currentTail));

    await previousTail.catch(() => {});

    try {
        const now = Date.now();
        const nextRequestAtMs = hostNextRequestAtMs.get(hostname) || now;
        const waitMs = Math.max(0, nextRequestAtMs - now);
        if (waitMs > 0) {
            await sleep(waitMs);
        }
        hostNextRequestAtMs.set(hostname, Date.now() + spacingMs);
    } finally {
        releaseCurrentTail();
    }
}

export async function getWithRetry({ api, operation, url, headers = {} }) {
    const method = 'GET';
    const retries = Number.isFinite(DEFAULT_MAX_RETRIES) && DEFAULT_MAX_RETRIES >= 0
        ? Math.trunc(DEFAULT_MAX_RETRIES)
        : 3;

    let attempt = 0;

    while (attempt <= retries) {
        await waitForRequestSpacing(url);
        const startedAt = Date.now();
        try {
            const response = await client.get(url, { headers });
            recordUpstreamApiRequest({
                api,
                operation,
                method,
                url,
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
                url,
                status,
                durationMs: Date.now() - startedAt
            });

            const retryable = shouldRetry(error);
            const hasAttemptsRemaining = attempt < retries;
            const retryReason = retryReasonFromError(error);
            const retryAfterMs = parseRetryAfterMs(error?.response?.headers?.['retry-after']);
            const effectiveRetryAfterMs = status === 429 && !Number.isFinite(retryAfterMs)
                ? DEFAULT_RATE_LIMIT_DELAY_FLOOR_MS
                : retryAfterMs;
            const backoffMs = retryable && hasAttemptsRemaining
                ? computeExponentialBackoffMs({
                    attemptNumber: attempt + 1,
                    baseDelayMs: DEFAULT_RETRY_BASE_DELAY_MS,
                    maxDelayMs: DEFAULT_RETRY_MAX_DELAY_MS,
                    retryAfterMs: effectiveRetryAfterMs
                })
                : null;

            if (status === 429) {
                logUpstreamRateLimit({
                    api,
                    operation,
                    method,
                    url,
                    status,
                    attempt: attempt + 1,
                    maxRetries: retries,
                    maxAttempts: retries + 1,
                    retryAfterMs,
                    backoffMs,
                    code: error?.code,
                    message: error?.message
                });
            }

            if (!retryable || !hasAttemptsRemaining) {
                if (retryable) {
                    recordUpstreamApiRetryExhausted({
                        api,
                        operation,
                        method,
                        url,
                        reason: retryReason,
                        status
                    });
                }
                throw error;
            }

            recordUpstreamApiRetry({
                api,
                operation,
                method,
                url,
                reason: retryReason,
                status,
                backoffMs
            });

            await sleep(backoffMs);
            attempt += 1;
        }
    }

    throw new Error('Upstream retry loop exited unexpectedly');
}
