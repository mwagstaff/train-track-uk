import client from 'prom-client';

// Create a Registry to register the metrics
const register = new client.Registry();

// Add default process/runtime metrics from Node.js.
client.collectDefaultMetrics({ register });

// HTTP request metrics (incoming API requests)
const httpRequestsTotal = new client.Counter({
    name: 'http_requests_total',
    help: 'Total number of HTTP requests',
    labelNames: ['method', 'path', 'status', 'api_version'],
    registers: [register]
});

const httpRequestDuration = new client.Histogram({
    name: 'http_request_duration_ms',
    help: 'Duration of HTTP requests in milliseconds',
    labelNames: ['method', 'path', 'status', 'api_version'],
    buckets: [10, 50, 100, 200, 500, 1000, 2000, 5000, 10000],
    registers: [register]
});

const v1RequestsTotal = new client.Counter({
    name: 'v1_requests_total',
    help: 'Total number of v1 API endpoint calls',
    registers: [register]
});

const v2RequestsTotal = new client.Counter({
    name: 'v2_requests_total',
    help: 'Total number of v2 API endpoint calls',
    registers: [register]
});

// Upstream API call metrics (Rail Data APIs etc.)
const upstreamApiRequestsTotal = new client.Counter({
    name: 'upstream_api_requests_total',
    help: 'Total number of upstream API call attempts (includes retries)',
    labelNames: ['api', 'operation', 'method', 'status', 'status_class', 'outcome'],
    registers: [register]
});

const upstreamApiRequestDuration = new client.Histogram({
    name: 'upstream_api_request_duration_ms',
    help: 'Upstream API call duration in milliseconds',
    labelNames: ['api', 'operation', 'method', 'status_class', 'outcome'],
    buckets: [25, 50, 100, 250, 500, 1000, 2000, 5000, 10000, 20000],
    registers: [register]
});

const upstreamApiRetriesTotal = new client.Counter({
    name: 'upstream_api_retries_total',
    help: 'Total number of upstream API retry attempts',
    labelNames: ['api', 'operation', 'method', 'reason', 'status'],
    registers: [register]
});

const upstreamApiRetryBackoff = new client.Histogram({
    name: 'upstream_api_retry_backoff_ms',
    help: 'Backoff delay before upstream API retries',
    labelNames: ['api', 'operation', 'method', 'reason'],
    buckets: [50, 100, 250, 500, 1000, 2000, 5000, 10000, 30000],
    registers: [register]
});

const upstreamApiRetryExhaustedTotal = new client.Counter({
    name: 'upstream_api_retry_exhausted_total',
    help: 'Total number of upstream API calls that exhausted retries',
    labelNames: ['api', 'operation', 'method', 'reason', 'status'],
    registers: [register]
});

// Push notification metrics (APNs)
const pushNotificationsTotal = new client.Counter({
    name: 'push_notifications_total',
    help: 'Total number of APNs push attempts (includes retries)',
    labelNames: ['channel', 'event', 'environment', 'status', 'status_class', 'outcome'],
    registers: [register]
});

const pushNotificationDuration = new client.Histogram({
    name: 'push_notification_duration_ms',
    help: 'APNs push request duration in milliseconds',
    labelNames: ['channel', 'event', 'environment', 'status_class', 'outcome'],
    buckets: [25, 50, 100, 250, 500, 1000, 2000, 5000, 10000],
    registers: [register]
});

const pushRetriesTotal = new client.Counter({
    name: 'push_retries_total',
    help: 'Total number of push retry attempts',
    labelNames: ['channel', 'event', 'environment', 'reason', 'status'],
    registers: [register]
});

const pushRetryBackoff = new client.Histogram({
    name: 'push_retry_backoff_ms',
    help: 'Backoff delay before push retry attempts',
    labelNames: ['channel', 'event', 'environment', 'reason'],
    buckets: [50, 100, 250, 500, 1000, 2000, 5000, 10000, 30000],
    registers: [register]
});

const pushRetryExhaustedTotal = new client.Counter({
    name: 'push_retry_exhausted_total',
    help: 'Total number of pushes that exhausted retries',
    labelNames: ['channel', 'event', 'environment', 'reason', 'status'],
    registers: [register]
});

const pushTokensRegisteredTotal = new client.Counter({
    name: 'push_tokens_registered_total',
    help: 'Total number of push token registrations',
    labelNames: ['channel', 'environment'],
    registers: [register]
});

const pushActiveSubscriptions = new client.Gauge({
    name: 'push_active_subscriptions',
    help: 'Current number of active push subscriptions by channel',
    labelNames: ['channel'],
    registers: [register]
});

// User and subscription activity gauges
const uniqueDevices1m = new client.Gauge({
    name: 'unique_devices_1m',
    help: 'Unique devices seen in the past 1 minute',
    registers: [register]
});

const uniqueDevices5m = new client.Gauge({
    name: 'unique_devices_5m',
    help: 'Unique devices seen in the past 5 minutes',
    registers: [register]
});

const uniqueDevices1h = new client.Gauge({
    name: 'unique_devices_1h',
    help: 'Unique devices seen in the past 1 hour',
    registers: [register]
});

const uniqueDevices24h = new client.Gauge({
    name: 'unique_devices_24h',
    help: 'Unique devices seen in the past 24 hours',
    registers: [register]
});

const notificationSubscriptions1m = new client.Gauge({
    name: 'notification_subscriptions_1m',
    help: 'Notification subscriptions active in the past 1 minute',
    registers: [register]
});

const notificationSubscriptions5m = new client.Gauge({
    name: 'notification_subscriptions_5m',
    help: 'Notification subscriptions active in the past 5 minutes',
    registers: [register]
});

const notificationSubscriptions1h = new client.Gauge({
    name: 'notification_subscriptions_1h',
    help: 'Notification subscriptions active in the past 1 hour',
    registers: [register]
});

const notificationSubscriptions24h = new client.Gauge({
    name: 'notification_subscriptions_24h',
    help: 'Notification subscriptions active in the past 24 hours',
    registers: [register]
});

// In-memory storage for calculating top URIs by duration.
const requestDurations = [];
const MAX_STORED_REQUESTS = 10000;

// Track when we last saw a device token so we can derive recent unique device counts.
const DEVICE_TOKEN_HEADER = 'x-device-token';
const DEVICE_RETENTION_MS = 48 * 60 * 60 * 1000;
const deviceLastSeen = new Map();

function normalizeStatus(status) {
    if (typeof status === 'number' && Number.isFinite(status)) {
        return String(Math.trunc(status));
    }
    if (typeof status === 'string' && status.length > 0) {
        return status;
    }
    return 'error';
}

function statusClass(status) {
    if (typeof status === 'number' && Number.isFinite(status)) {
        const klass = Math.floor(status / 100);
        if (klass >= 1 && klass <= 5) {
            return `${klass}xx`;
        }
    }
    return 'error';
}

function outcomeFromStatus(status) {
    if (typeof status === 'number' && Number.isFinite(status)) {
        return status < 400 ? 'success' : 'failure';
    }
    return 'failure';
}

function asLabel(value, fallback = 'unknown') {
    return typeof value === 'string' && value.length > 0 ? value : fallback;
}

// Middleware to track metrics for inbound HTTP requests.
export function metricsMiddleware(req, res, next) {
    const start = Date.now();

    cleanupOldDevices(start);
    recordDeviceSeen(req, start);

    const originalEnd = res.end;

    res.end = function(...args) {
        const duration = Date.now() - start;
        const path = req.route ? req.route.path : req.path;
        const status = res.statusCode;
        const method = req.method;

        let apiVersion = 'other';
        if (path.startsWith('/api/v1')) {
            apiVersion = 'v1';
            v1RequestsTotal.inc();
        } else if (path.startsWith('/api/v2')) {
            apiVersion = 'v2';
            v2RequestsTotal.inc();
        }

        httpRequestsTotal.inc({ method, path, status, api_version: apiVersion });
        httpRequestDuration.observe({ method, path, status, api_version: apiVersion }, duration);

        requestDurations.push({ path, duration, timestamp: Date.now() });
        if (requestDurations.length > MAX_STORED_REQUESTS) {
            requestDurations.shift();
        }

        originalEnd.apply(res, args);
    };

    next();
}

export function recordUpstreamApiRequest({ api, operation, method, status, durationMs }) {
    const apiLabel = asLabel(api);
    const operationLabel = asLabel(operation);
    const methodLabel = asLabel(method, 'GET').toUpperCase();
    const statusLabel = normalizeStatus(status);
    const statusClassLabel = statusClass(status);
    const outcomeLabel = outcomeFromStatus(status);

    upstreamApiRequestsTotal.inc({
        api: apiLabel,
        operation: operationLabel,
        method: methodLabel,
        status: statusLabel,
        status_class: statusClassLabel,
        outcome: outcomeLabel
    });

    upstreamApiRequestDuration.observe(
        {
            api: apiLabel,
            operation: operationLabel,
            method: methodLabel,
            status_class: statusClassLabel,
            outcome: outcomeLabel
        },
        Math.max(0, Number(durationMs) || 0)
    );
}

export function recordUpstreamApiRetry({ api, operation, method, reason, status, backoffMs }) {
    const apiLabel = asLabel(api);
    const operationLabel = asLabel(operation);
    const methodLabel = asLabel(method, 'GET').toUpperCase();
    const reasonLabel = asLabel(reason);
    const statusLabel = normalizeStatus(status);

    upstreamApiRetriesTotal.inc({
        api: apiLabel,
        operation: operationLabel,
        method: methodLabel,
        reason: reasonLabel,
        status: statusLabel
    });

    upstreamApiRetryBackoff.observe(
        {
            api: apiLabel,
            operation: operationLabel,
            method: methodLabel,
            reason: reasonLabel
        },
        Math.max(0, Number(backoffMs) || 0)
    );
}

export function recordUpstreamApiRetryExhausted({ api, operation, method, reason, status }) {
    upstreamApiRetryExhaustedTotal.inc({
        api: asLabel(api),
        operation: asLabel(operation),
        method: asLabel(method, 'GET').toUpperCase(),
        reason: asLabel(reason),
        status: normalizeStatus(status)
    });
}

export function recordPushNotification({ channel, event, environment, status, durationMs }) {
    const channelLabel = asLabel(channel);
    const eventLabel = asLabel(event);
    const environmentLabel = asLabel(environment, 'prod');
    const statusLabel = normalizeStatus(status);
    const statusClassLabel = statusClass(status);
    const outcomeLabel = outcomeFromStatus(status);

    pushNotificationsTotal.inc({
        channel: channelLabel,
        event: eventLabel,
        environment: environmentLabel,
        status: statusLabel,
        status_class: statusClassLabel,
        outcome: outcomeLabel
    });

    pushNotificationDuration.observe(
        {
            channel: channelLabel,
            event: eventLabel,
            environment: environmentLabel,
            status_class: statusClassLabel,
            outcome: outcomeLabel
        },
        Math.max(0, Number(durationMs) || 0)
    );
}

export function recordPushRetry({ channel, event, environment, reason, status, backoffMs }) {
    const channelLabel = asLabel(channel);
    const eventLabel = asLabel(event);
    const environmentLabel = asLabel(environment, 'prod');
    const reasonLabel = asLabel(reason);
    const statusLabel = normalizeStatus(status);

    pushRetriesTotal.inc({
        channel: channelLabel,
        event: eventLabel,
        environment: environmentLabel,
        reason: reasonLabel,
        status: statusLabel
    });

    pushRetryBackoff.observe(
        {
            channel: channelLabel,
            event: eventLabel,
            environment: environmentLabel,
            reason: reasonLabel
        },
        Math.max(0, Number(backoffMs) || 0)
    );
}

export function recordPushRetryExhausted({ channel, event, environment, reason, status }) {
    pushRetryExhaustedTotal.inc({
        channel: asLabel(channel),
        event: asLabel(event),
        environment: asLabel(environment, 'prod'),
        reason: asLabel(reason),
        status: normalizeStatus(status)
    });
}

export function recordPushTokenRegistration({ channel, environment }) {
    pushTokensRegisteredTotal.inc({
        channel: asLabel(channel),
        environment: asLabel(environment, 'prod')
    });
}

export function updatePushSubscriptionGauges({ notification = 0, liveActivity = 0 } = {}) {
    pushActiveSubscriptions.set({ channel: 'notification' }, Math.max(0, Number(notification) || 0));
    pushActiveSubscriptions.set({ channel: 'live_activity' }, Math.max(0, Number(liveActivity) || 0));
}

function extractDeviceToken(req) {
    if (!req) return null;
    const headerTokenRaw = req.headers?.[DEVICE_TOKEN_HEADER];
    const headerToken = Array.isArray(headerTokenRaw) ? headerTokenRaw[0] : headerTokenRaw;
    if (typeof headerToken === 'string' && headerToken.trim().length > 0) {
        return headerToken.trim();
    }
    const body = req.body || {};
    const bodyToken = body.device_token || body.deviceToken || body.device_id || body.deviceId;
    if (typeof bodyToken === 'string' && bodyToken.trim().length > 0) {
        return bodyToken.trim();
    }
    return null;
}

function recordDeviceSeen(req, now = Date.now()) {
    const token = extractDeviceToken(req);
    if (!token) return;
    deviceLastSeen.set(token, now);
}

function cleanupOldDevices(now = Date.now()) {
    const cutoff = now - DEVICE_RETENTION_MS;
    for (const [token, ts] of deviceLastSeen.entries()) {
        if (ts < cutoff) {
            deviceLastSeen.delete(token);
        }
    }
}

function countUniqueDevices(windowMs, now = Date.now()) {
    const cutoff = now - windowMs;
    let count = 0;
    for (const ts of deviceLastSeen.values()) {
        if (ts >= cutoff) {
            count++;
        }
    }
    return count;
}

function updateDeviceGauges(now = Date.now()) {
    cleanupOldDevices(now);
    uniqueDevices1m.set(countUniqueDevices(60 * 1000, now));
    uniqueDevices5m.set(countUniqueDevices(5 * 60 * 1000, now));
    uniqueDevices1h.set(countUniqueDevices(60 * 60 * 1000, now));
    uniqueDevices24h.set(countUniqueDevices(24 * 60 * 60 * 1000, now));
}

function getTopUrisByDuration() {
    const sorted = [...requestDurations].sort((a, b) => b.duration - a.duration).slice(0, 10);

    let output = '';
    sorted.forEach((item, index) => {
        output += `# HELP top_uri_duration_${index + 1} Top ${index + 1} URI by request duration\n`;
        output += `# TYPE top_uri_duration_${index + 1} gauge\n`;
        output += `top_uri_duration_${index + 1}{path="${item.path}"} ${item.duration}\n`;
    });

    return output;
}

function calculatePercentiles() {
    if (requestDurations.length === 0) {
        return { min: 0, max: 0, avg: 0, p90: 0, p95: 0, p99: 0 };
    }

    const durations = requestDurations.map(r => r.duration).sort((a, b) => a - b);
    const count = durations.length;

    const min = durations[0];
    const max = durations[count - 1];
    const avg = durations.reduce((sum, d) => sum + d, 0) / count;

    const p90Index = Math.floor(count * 0.90);
    const p95Index = Math.floor(count * 0.95);
    const p99Index = Math.floor(count * 0.99);

    const p90 = durations[Math.min(p90Index, count - 1)];
    const p95 = durations[Math.min(p95Index, count - 1)];
    const p99 = durations[Math.min(p99Index, count - 1)];

    return { min, max, avg, p90, p95, p99 };
}

// Export metrics in Prometheus format.
export async function getMetrics() {
    updateDeviceGauges();

    let metrics = await register.metrics();

    const percentiles = calculatePercentiles();

    metrics += '\n# HELP http_request_duration_min_ms Minimum HTTP request duration in milliseconds\n';
    metrics += '# TYPE http_request_duration_min_ms gauge\n';
    metrics += `http_request_duration_min_ms ${percentiles.min}\n`;

    metrics += '\n# HELP http_request_duration_max_ms Maximum HTTP request duration in milliseconds\n';
    metrics += '# TYPE http_request_duration_max_ms gauge\n';
    metrics += `http_request_duration_max_ms ${percentiles.max}\n`;

    metrics += '\n# HELP http_request_duration_avg_ms Average HTTP request duration in milliseconds\n';
    metrics += '# TYPE http_request_duration_avg_ms gauge\n';
    metrics += `http_request_duration_avg_ms ${percentiles.avg}\n`;

    metrics += '\n# HELP http_request_duration_p90_ms 90th percentile HTTP request duration in milliseconds\n';
    metrics += '# TYPE http_request_duration_p90_ms gauge\n';
    metrics += `http_request_duration_p90_ms ${percentiles.p90}\n`;

    metrics += '\n# HELP http_request_duration_p95_ms 95th percentile HTTP request duration in milliseconds\n';
    metrics += '# TYPE http_request_duration_p95_ms gauge\n';
    metrics += `http_request_duration_p95_ms ${percentiles.p95}\n`;

    metrics += '\n# HELP http_request_duration_p99_ms 99th percentile HTTP request duration in milliseconds\n';
    metrics += '# TYPE http_request_duration_p99_ms gauge\n';
    metrics += `http_request_duration_p99_ms ${percentiles.p99}\n`;

    metrics += '\n' + getTopUrisByDuration();

    return metrics;
}

export function updateNotificationSubscriptionGauges(counts = {}) {
    notificationSubscriptions1m.set(Number(counts.last1m || 0));
    notificationSubscriptions5m.set(Number(counts.last5m || 0));
    notificationSubscriptions1h.set(Number(counts.last1h || 0));
    notificationSubscriptions24h.set(Number(counts.last24h || 0));
}
