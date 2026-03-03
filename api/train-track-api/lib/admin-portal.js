import {
    getNotificationEvent,
    getNotificationSubscriptionFromRedis,
    listNotificationEvents,
    listNotificationSubscriptionsFromRedis
} from './admin-data-store.js';

const DEFAULT_LIMIT = 500;

export function registerAdminRoutes(app) {
    app.get('/admin', async (req, res) => {
        try {
            const query = typeof req.query?.q === 'string' ? req.query.q.trim() : '';
            const limit = clampLimit(req.query?.limit, 1, 5000, DEFAULT_LIMIT);
            const [subscriptions, notifications] = await Promise.all([
                listNotificationSubscriptionsFromRedis({ search: query, limit }),
                listNotificationEvents({ search: query, limit })
            ]);
            res.type('html').send(renderAdminPage({
                query,
                limit,
                subscriptions,
                notifications
            }));
        } catch (error) {
            console.error('[admin] Failed to load dashboard:', error?.message || error);
            res.status(500).type('html').send(renderErrorPage('Failed to load admin dashboard.'));
        }
    });

    app.get('/admin/subscriptions/:id', async (req, res) => {
        try {
            const id = req.params?.id;
            const subscription = await getNotificationSubscriptionFromRedis(id);
            if (!subscription) {
                return res.status(404).type('html').send(renderErrorPage(`Subscription not found: ${id}`));
            }
            res.type('html').send(renderJsonDetailPage({
                title: `Subscription ${subscription.id}`,
                backHref: '../../admin',
                payload: subscription
            }));
        } catch (error) {
            console.error('[admin] Failed to load subscription detail:', error?.message || error);
            res.status(500).type('html').send(renderErrorPage('Failed to load subscription detail.'));
        }
    });

    app.get('/admin/notifications/:id', async (req, res) => {
        try {
            const id = req.params?.id;
            const event = await getNotificationEvent(id);
            if (!event) {
                return res.status(404).type('html').send(renderErrorPage(`Notification event not found: ${id}`));
            }
            res.type('html').send(renderJsonDetailPage({
                title: `Notification Event ${event.id}`,
                backHref: '../../admin',
                payload: event
            }));
        } catch (error) {
            console.error('[admin] Failed to load notification detail:', error?.message || error);
            res.status(500).type('html').send(renderErrorPage('Failed to load notification detail.'));
        }
    });
}

function renderAdminPage({ query, limit, subscriptions, notifications }) {
    const subscriptionRows = subscriptions.map((subscription) => {
        const scheduleStart = formatLegSchedule(subscription.legs, 'windowStart');
        const scheduleEnd = formatLegSchedule(subscription.legs, 'windowEnd');
        const stationNames = formatStationNames(subscription.legs);
        const days = formatDays(subscription.daysOfWeek);
        return `
            <tr>
                <td>${escapeHtml(subscription.id || '')}</td>
                <td>${formatDate(subscription.createdAt)}</td>
                <td class="token">${escapeHtml(subscription.pushToken || '')}</td>
                <td>${subscription.useSandbox ? 'sandbox' : 'prod'}</td>
                <td>${escapeHtml(stationNames)}</td>
                <td>${escapeHtml(scheduleStart)}</td>
                <td>${escapeHtml(scheduleEnd)}</td>
                <td>${escapeHtml(days)}</td>
                <td><a href="admin/subscriptions/${encodeURIComponent(subscription.id || '')}">View JSON</a></td>
            </tr>
        `;
    }).join('');

    const notificationRows = notifications.map((event) => `
        <tr>
            <td>${formatDate(event.sent_at)}</td>
            <td>${escapeHtml(event.channel || '')}</td>
            <td>${escapeHtml(event.type || '')}</td>
            <td>${escapeHtml(event.success ? 'success' : 'failure')}</td>
            <td>${escapeHtml(formatStatus(event.status))}</td>
            <td>${escapeHtml(event.error || '')}</td>
            <td>${escapeHtml(event.apns_environment || '')}</td>
            <td>${escapeHtml(event.subscription_id || event.activity_id || '')}</td>
            <td><a href="admin/notifications/${encodeURIComponent(event.id || '')}">View JSON</a></td>
        </tr>
    `).join('');

    const qValue = escapeHtml(query || '');
    const clearHref = '?';
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Train Track Admin</title>
    <style>
        :root {
            --bg: #f3f6fa;
            --panel: #ffffff;
            --line: #d9e1eb;
            --text: #172433;
            --muted: #5e6d82;
            --accent: #0057b8;
        }
        body {
            margin: 0;
            font-family: "Segoe UI", "Helvetica Neue", Helvetica, Arial, sans-serif;
            color: var(--text);
            background: linear-gradient(145deg, #f3f6fa, #eaf0f7);
        }
        .wrap {
            max-width: 1400px;
            margin: 24px auto 48px;
            padding: 0 16px;
        }
        h1 {
            margin: 0 0 6px;
            font-size: 28px;
        }
        .meta {
            color: var(--muted);
            margin-bottom: 18px;
        }
        .search {
            display: flex;
            gap: 8px;
            margin-bottom: 18px;
            flex-wrap: wrap;
        }
        .search input {
            min-width: 260px;
            flex: 1;
            max-width: 460px;
            border: 1px solid var(--line);
            border-radius: 8px;
            padding: 10px 12px;
            font-size: 14px;
            background: #fff;
        }
        .search button,
        .search a {
            border-radius: 8px;
            padding: 10px 14px;
            font-size: 14px;
            text-decoration: none;
            border: 1px solid var(--line);
            background: #fff;
            color: var(--text);
            cursor: pointer;
        }
        .search button {
            background: var(--accent);
            color: white;
            border-color: var(--accent);
        }
        .panel {
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 12px;
            margin-bottom: 18px;
            overflow: hidden;
            box-shadow: 0 6px 18px rgba(15, 44, 78, 0.08);
        }
        .panel h2 {
            margin: 0;
            padding: 14px 16px;
            border-bottom: 1px solid var(--line);
            font-size: 19px;
            background: #fbfcff;
        }
        .table-wrap {
            overflow-x: auto;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            min-width: 920px;
        }
        th, td {
            text-align: left;
            border-bottom: 1px solid var(--line);
            padding: 10px 12px;
            vertical-align: top;
            font-size: 13px;
        }
        th {
            color: #33445b;
            font-weight: 600;
            background: #fbfcff;
        }
        tr:last-child td {
            border-bottom: none;
        }
        .token {
            max-width: 280px;
            word-break: break-all;
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
        }
        .empty {
            padding: 16px;
            color: var(--muted);
        }
    </style>
</head>
<body>
    <div class="wrap">
        <h1>Admin Portal</h1>
        <div class="meta">Redis-backed view of subscriptions and APNS notifications (limit ${limit} each table).</div>
        <form class="search" method="GET" action="">
            <input type="text" name="q" value="${qValue}" placeholder="Search by token, station, route, status, or error text" />
            <input type="hidden" name="limit" value="${limit}" />
            <button type="submit">Search</button>
            <a href="${clearHref}">Clear</a>
        </form>

        <section class="panel">
            <h2>Live Subscription Data (${subscriptions.length})</h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>ID</th>
                            <th>Activation Date</th>
                            <th>Token</th>
                            <th>APNS Env</th>
                            <th>Station Names</th>
                            <th>Schedule Start</th>
                            <th>Schedule End</th>
                            <th>Days</th>
                            <th>Raw</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${subscriptionRows || `<tr><td class="empty" colspan="9">No subscriptions found.</td></tr>`}
                    </tbody>
                </table>
            </div>
        </section>

        <section class="panel">
            <h2>Notification Sends (${notifications.length})</h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Sent At</th>
                            <th>Channel</th>
                            <th>Type</th>
                            <th>Success</th>
                            <th>Status</th>
                            <th>Error</th>
                            <th>APNS Env</th>
                            <th>Subscription/Activity</th>
                            <th>Raw</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${notificationRows || `<tr><td class="empty" colspan="9">No notifications found.</td></tr>`}
                    </tbody>
                </table>
            </div>
        </section>
    </div>
</body>
</html>`;
}

function renderJsonDetailPage({ title, backHref, payload }) {
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapeHtml(title)}</title>
    <style>
        body {
            margin: 0;
            padding: 24px;
            font-family: "Segoe UI", "Helvetica Neue", Helvetica, Arial, sans-serif;
            background: #f4f7fb;
            color: #172433;
        }
        a {
            color: #0057b8;
            text-decoration: none;
        }
        h1 {
            margin-top: 0;
            font-size: 24px;
        }
        pre {
            margin: 16px 0 0;
            padding: 16px;
            border: 1px solid #d9e1eb;
            border-radius: 12px;
            background: #fff;
            overflow: auto;
            line-height: 1.5;
            font-size: 13px;
        }
    </style>
</head>
<body>
    <a href="${escapeHtml(backHref)}">Back to Admin</a>
    <h1>${escapeHtml(title)}</h1>
    <pre>${escapeHtml(JSON.stringify(payload, null, 2))}</pre>
</body>
</html>`;
}

function renderErrorPage(message) {
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Admin Error</title>
    <style>
        body {
            margin: 0;
            font-family: "Segoe UI", "Helvetica Neue", Helvetica, Arial, sans-serif;
            background: #f7f9fc;
            color: #172433;
            padding: 24px;
        }
        .panel {
            background: #fff;
            border: 1px solid #d9e1eb;
            border-radius: 12px;
            padding: 16px;
            max-width: 720px;
        }
    </style>
</head>
<body>
    <div class="panel">${escapeHtml(message)}</div>
</body>
</html>`;
}

function formatStationNames(legs) {
    if (!Array.isArray(legs)) return '';
    return legs
        .filter((leg) => leg && leg.enabled !== false)
        .map((leg) => `${leg.fromName || leg.from || ''} -> ${leg.toName || leg.to || ''}`)
        .join('; ');
}

function formatLegSchedule(legs, field) {
    if (!Array.isArray(legs)) return '';
    return legs
        .filter((leg) => leg && leg.enabled !== false)
        .map((leg) => {
            const value = leg[field] || '';
            const stationPair = `${leg.fromName || leg.from || ''} -> ${leg.toName || leg.to || ''}`;
            return `${value} (${stationPair})`;
        })
        .join('; ');
}

function formatDays(daysInput) {
    const order = new Map([
        ['mon', 0],
        ['tue', 1],
        ['wed', 2],
        ['thu', 3],
        ['fri', 4],
        ['sat', 5],
        ['sun', 6]
    ]);
    if (!Array.isArray(daysInput)) return '';
    return daysInput
        .map((day) => (typeof day === 'string' ? day.trim().toLowerCase().slice(0, 3) : ''))
        .filter((day) => order.has(day))
        .sort((a, b) => order.get(a) - order.get(b))
        .map((day) => day.charAt(0).toUpperCase() + day.slice(1))
        .join(', ');
}

function formatDate(value) {
    if (!value) return '';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return escapeHtml(String(value));
    return escapeHtml(date.toISOString());
}

function formatStatus(status) {
    if (status === undefined || status === null) return '';
    return String(status);
}

function escapeHtml(input) {
    const text = String(input ?? '');
    return text
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function clampLimit(value, min, max, fallback) {
    const number = Number(value);
    if (!Number.isFinite(number)) return fallback;
    return Math.min(max, Math.max(min, Math.floor(number)));
}
