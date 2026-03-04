export const RETRYABLE_HTTP_STATUS_CODES = new Set([429, 500, 503]);

export function isRetryableHttpStatus(status) {
    return typeof status === 'number' && RETRYABLE_HTTP_STATUS_CODES.has(status);
}

export function retryReasonFromError(error) {
    const status = error?.response?.status;
    if (isRetryableHttpStatus(status)) {
        return `http_${status}`;
    }
    const code = error?.code;
    if (typeof code === 'string' && code.length > 0) {
        return code.toLowerCase();
    }
    if (error?.response) {
        return 'http_error';
    }
    return 'network_error';
}

export function parseRetryAfterMs(retryAfterHeaderValue, now = Date.now()) {
    if (retryAfterHeaderValue === undefined || retryAfterHeaderValue === null) {
        return null;
    }

    if (typeof retryAfterHeaderValue === 'number' && Number.isFinite(retryAfterHeaderValue)) {
        return Math.max(0, Math.trunc(retryAfterHeaderValue * 1000));
    }

    if (typeof retryAfterHeaderValue !== 'string') {
        return null;
    }

    const numericSeconds = Number(retryAfterHeaderValue);
    if (Number.isFinite(numericSeconds)) {
        return Math.max(0, Math.trunc(numericSeconds * 1000));
    }

    const parsedDate = Date.parse(retryAfterHeaderValue);
    if (!Number.isNaN(parsedDate)) {
        return Math.max(0, parsedDate - now);
    }

    return null;
}

export function computeExponentialBackoffMs({
    attemptNumber,
    baseDelayMs = 300,
    maxDelayMs = 15000,
    retryAfterMs = null,
    jitterRatio = 0.2
} = {}) {
    const attempt = Math.max(1, Math.trunc(Number(attemptNumber) || 1));
    const base = Math.max(0, Number(baseDelayMs) || 0);
    const max = Math.max(base, Number(maxDelayMs) || base);

    const withoutJitter = Math.min(max, base * (2 ** (attempt - 1)));
    const jitterRange = withoutJitter * Math.max(0, Number(jitterRatio) || 0);
    const jitter = (Math.random() * jitterRange * 2) - jitterRange;

    const backoff = Math.max(0, Math.round(withoutJitter + jitter));

    if (typeof retryAfterMs === 'number' && Number.isFinite(retryAfterMs) && retryAfterMs > 0) {
        return Math.max(backoff, Math.min(max, Math.round(retryAfterMs)));
    }

    return backoff;
}

export async function sleep(ms) {
    const delay = Math.max(0, Math.trunc(Number(ms) || 0));
    if (delay === 0) {
        return;
    }
    await new Promise((resolve) => setTimeout(resolve, delay));
}
