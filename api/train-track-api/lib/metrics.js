import client from 'prom-client';

// Create a Registry to register the metrics
const register = new client.Registry();

// Add default metrics (like Node.js process metrics)
client.collectDefaultMetrics({ register });

// Custom metrics
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

// In-memory storage for calculating top URIs by duration
const requestDurations = [];
const MAX_STORED_REQUESTS = 10000; // Keep last 10k requests for top URI calculation

// Track when we last saw a device token so we can derive recent unique device counts
const DEVICE_TOKEN_HEADER = 'x-device-token';
const DEVICE_RETENTION_MS = 48 * 60 * 60 * 1000; // Keep a 48h window to cover 24h metric plus buffer
const deviceLastSeen = new Map();

// Middleware to track metrics
export function metricsMiddleware(req, res, next) {
    const start = Date.now();

    cleanupOldDevices(start);
    recordDeviceSeen(req, start);

    // Capture the original end function
    const originalEnd = res.end;

    // Override res.end to capture metrics when response completes
    res.end = function(...args) {
        const duration = Date.now() - start;
        const path = req.route ? req.route.path : req.path;
        const status = res.statusCode;
        const method = req.method;

        // Determine API version
        let apiVersion = 'other';
        if (path.startsWith('/api/v1')) {
            apiVersion = 'v1';
            v1RequestsTotal.inc();
        } else if (path.startsWith('/api/v2')) {
            apiVersion = 'v2';
            v2RequestsTotal.inc();
        }

        // Record metrics
        httpRequestsTotal.inc({ method, path, status, api_version: apiVersion });
        httpRequestDuration.observe({ method, path, status, api_version: apiVersion }, duration);

        // Store request duration for top URIs calculation
        requestDurations.push({ path, duration, timestamp: Date.now() });

        // Keep only the last MAX_STORED_REQUESTS
        if (requestDurations.length > MAX_STORED_REQUESTS) {
            requestDurations.shift();
        }

        // Call the original end function
        originalEnd.apply(res, args);
    };

    next();
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

// Function to get top 10 URIs by request duration
function getTopUrisByDuration() {
    // Sort by duration descending and take top 10
    const sorted = [...requestDurations].sort((a, b) => b.duration - a.duration).slice(0, 10);

    let output = '';
    sorted.forEach((item, index) => {
        output += `# HELP top_uri_duration_${index + 1} Top ${index + 1} URI by request duration\n`;
        output += `# TYPE top_uri_duration_${index + 1} gauge\n`;
        output += `top_uri_duration_${index + 1}{path="${item.path}"} ${item.duration}\n`;
    });

    return output;
}

// Function to calculate percentiles
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

// Export metrics in Prometheus format
export async function getMetrics() {
    updateDeviceGauges();

    // Get default metrics from the registry
    let metrics = await register.metrics();

    // Add custom percentile metrics
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

    // Add top URIs by duration
    metrics += '\n' + getTopUrisByDuration();

    return metrics;
}

export function updateNotificationSubscriptionGauges(counts = {}) {
    notificationSubscriptions1m.set(Number(counts.last1m || 0));
    notificationSubscriptions5m.set(Number(counts.last5m || 0));
    notificationSubscriptions1h.set(Number(counts.last1h || 0));
    notificationSubscriptions24h.set(Number(counts.last24h || 0));
}
