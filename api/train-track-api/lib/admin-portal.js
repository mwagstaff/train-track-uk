import {
    getNotificationEvent,
    getNotificationSubscriptionFromRedis,
    listNotificationEvents,
    listNotificationSubscriptionsFromRedis,
    listGeofenceEvents
} from './admin-data-store.js';
import { liveActivityManager } from './live-activity-manager.js';

const DEFAULT_LIMIT = 500;
const DEFAULT_NOTIFICATION_LIMIT = 20;

export function registerAdminRoutes(app) {
    app.get('/admin', async (req, res) => {
        try {
            const query = typeof req.query?.q === 'string' ? req.query.q.trim() : '';
            const limit = clampLimit(req.query?.limit, 1, 5000, DEFAULT_LIMIT);
            const [subscriptions, notifications, geofenceEvents] = await Promise.all([
                listNotificationSubscriptionsFromRedis({ search: query, limit }),
                listNotificationEvents({ search: query, limit: DEFAULT_NOTIFICATION_LIMIT }),
                listGeofenceEvents()
            ]);
            const liveActivitySessions = liveActivityManager.listSubscriptions();
            res.type('html').send(renderAdminPage({
                query,
                limit,
                subscriptions,
                notifications,
                geofenceEvents,
                liveActivitySessions
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

function renderAdminPage({ query, limit, subscriptions, notifications, geofenceEvents = [], liveActivitySessions = [] }) {
    const now = new Date();
    const scheduledSubscriptions = subscriptions.filter((subscription) => subscription?.source !== 'live_session');

    // ── Live Activity Sessions (in-memory) ───────────────────────────────────
    const liveActivityRows = liveActivitySessions.length === 0
        ? `<tr><td class="empty" colspan="11">No active live activity sessions.</td></tr>`
        : liveActivitySessions
            .sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0))
            .map((s) => {
                const lastPushAgo = s.lastPushAt ? relativeTime(new Date(s.lastPushAt), now) : '<span class="never">never</span>';
                const lastCheckinAgo = s.lastAppCheckInAt ? relativeTime(new Date(s.lastAppCheckInAt), now) : '<span class="never">never</span>';
                const expiresIn = s.endAt ? relativeTime(now, new Date(s.endAt)) : '—';
                const devShort = escapeHtml(shortId(s.deviceId));
                const actShort = escapeHtml(shortId(s.activityId));
                const route = escapeHtml(`${s.fromStation || '?'} → ${s.toStation || '?'}`);
                const env = s.useSandbox ? '<span class="badge badge-sandbox">sandbox</span>' : '<span class="badge badge-prod">prod</span>';
                const mute = s.muteOnArrival ? '✅' : '—';
                return `<tr>
                    <td title="${escapeHtml(s.deviceId || '')}">${devShort}</td>
                    <td title="${escapeHtml(s.activityId || '')}">${actShort}</td>
                    <td><strong>${route}</strong></td>
                    <td>${env}</td>
                    <td>${formatDate(s.createdAt)}</td>
                    <td>${formatDate(s.lastPushAt) || '<span class="never">—</span>'}</td>
                    <td>${lastPushAgo}</td>
                    <td title="${escapeHtml(s.lastAppCheckInAt || '')}">${lastCheckinAgo}</td>
                    <td>${escapeHtml(expiresIn)}</td>
                    <td>${escapeHtml(String(s.revision))}</td>
                    <td>${mute}</td>
                </tr>`;
            }).join('');

    // ── Scheduled notification subscriptions ─────────────────────────────────
    const subscriptionRows = scheduledSubscriptions.map((subscription) => {
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

    // ── Notification events ──────────────────────────────────────────────────
    const notificationRows = notifications.map((event) => {
        const successCell = event.success
            ? '<span class="badge badge-ok">✓ ok</span>'
            : '<span class="badge badge-err">✗ fail</span>';
        const typeClass = event.type?.includes('register') ? 'type-register'
            : event.type?.includes('update') ? 'type-update'
            : event.type?.includes('end') ? 'type-end'
            : event.type?.includes('rotation') ? 'type-rotation'
            : '';
        const hasAlert = Boolean(event.payload?.aps?.alert);
        const devShort = escapeHtml(shortId(event.device_id));
        const route = (event.from_station && event.to_station)
            ? escapeHtml(`${event.from_station} → ${event.to_station}`)
            : escapeHtml(event.route_key || '');
        const alertBadge = hasAlert ? ' <span class="badge badge-alert" title="Push included aps.alert — banner shown">🔔 alert</span>' : '';
        return `<tr>
            <td>${formatDate(event.sent_at)}</td>
            <td title="${escapeHtml(event.device_id || '')}">${devShort}</td>
            <td>${escapeHtml(event.channel || '')}</td>
            <td><span class="${typeClass}">${escapeHtml(event.type || '')}</span>${alertBadge}</td>
            <td>${route}</td>
            <td>${successCell}</td>
            <td>${escapeHtml(formatStatus(event.status))}</td>
            <td>${escapeHtml(event.error || '')}</td>
            <td>${escapeHtml(event.apns_environment || '')}</td>
            <td><a href="admin/notifications/${encodeURIComponent(event.id || '')}">JSON</a></td>
        </tr>`;
    }).join('');

    // ── Geofence events ──────────────────────────────────────────────────────
    const geofenceEventRows = geofenceEvents.map((ev) => {
        const eventLabel = ev.event === 'enter'
            ? '<span class="badge badge-enter">▶ enter</span>'
            : '<span class="badge badge-exit">◀ exit</span>';
        const devShort = escapeHtml(shortId(ev.device_id));
        return `<tr>
            <td>${formatDate(ev.received_at)}</td>
            <td>${eventLabel}</td>
            <td><strong>${escapeHtml(ev.from || '')}</strong></td>
            <td><strong>${escapeHtml(ev.to || '')}</strong></td>
            <td>${formatDate(ev.client_timestamp)}</td>
            <td title="${escapeHtml(ev.device_id || '')}">${devShort}</td>
        </tr>`;
    }).join('');

    const qValue = escapeHtml(query || '');
    const clearHref = '?';
    const renderedAt = escapeHtml(now.toISOString());
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta http-equiv="refresh" content="30" />
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
        .wrap { max-width: 1500px; margin: 24px auto 48px; padding: 0 16px; }
        h1 { margin: 0 0 4px; font-size: 28px; }
        .meta { color: var(--muted); margin-bottom: 18px; font-size: 13px; }
        .search { display: flex; gap: 8px; margin-bottom: 18px; flex-wrap: wrap; }
        .search input {
            min-width: 260px; flex: 1; max-width: 460px;
            border: 1px solid var(--line); border-radius: 8px;
            padding: 10px 12px; font-size: 14px; background: #fff;
        }
        .search button, .search a {
            border-radius: 8px; padding: 10px 14px; font-size: 14px;
            text-decoration: none; border: 1px solid var(--line);
            background: #fff; color: var(--text); cursor: pointer;
        }
        .search button { background: var(--accent); color: white; border-color: var(--accent); }
        .panel {
            background: var(--panel); border: 1px solid var(--line);
            border-radius: 12px; margin-bottom: 18px; overflow: hidden;
            box-shadow: 0 6px 18px rgba(15,44,78,0.08);
        }
        .panel h2 {
            margin: 0; padding: 14px 16px; border-bottom: 1px solid var(--line);
            font-size: 17px; background: #fbfcff;
            display: flex; align-items: center; gap: 10px;
        }
        .panel-count {
            background: #e8eef8; color: #1a4a8a; border-radius: 10px;
            padding: 2px 8px; font-size: 12px; font-weight: 600;
        }
        .table-wrap { overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; min-width: 900px; }
        th, td {
            text-align: left; border-bottom: 1px solid var(--line);
            padding: 9px 11px; vertical-align: top; font-size: 12.5px;
        }
        th { color: #33445b; font-weight: 600; background: #fbfcff; white-space: nowrap; }
        tr:last-child td { border-bottom: none; }
        tr:hover td { background: #f6f9ff; }
        .token { max-width: 220px; word-break: break-all; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 11px; }
        .empty { padding: 16px; color: var(--muted); }
        .never { color: #999; font-style: italic; }
        .badge {
            display: inline-block; border-radius: 6px; padding: 2px 7px;
            font-size: 11px; font-weight: 600; white-space: nowrap;
        }
        .badge-ok     { background:#d4f5e2; color:#0d6632; }
        .badge-err    { background:#fde8e8; color:#b91c1c; }
        .badge-sandbox { background:#fef3c7; color:#92400e; }
        .badge-prod   { background:#dbeafe; color:#1e40af; }
        .badge-enter  { background:#d1fae5; color:#065f46; }
        .badge-exit   { background:#ffedd5; color:#9a3412; }
        .type-register { color:#1d4ed8; font-weight:600; }
        .type-update  { color:#059669; }
        .type-end     { color:#7c3aed; }
        .type-rotation { color:#d97706; }
        .badge-alert  { background:#fef3c7; color:#92400e; }
    </style>
</head>
<body>
    <div class="wrap">
        <h1>🚂 Train Track Admin</h1>
        <div class="meta">Rendered at ${renderedAt} · Auto-refreshes every 30 s · Showing up to ${limit} rows per table</div>
        <form class="search" method="GET" action="">
            <input type="text" name="q" value="${qValue}" placeholder="Search by token, station, route, status, or error text" />
            <input type="hidden" name="limit" value="${limit}" />
            <button type="submit">Search</button>
            <a href="${clearHref}">Clear</a>
        </form>

        <section class="panel">
            <h2>📡 Live Activity Sessions (in-memory) <span class="panel-count">${liveActivitySessions.length} active</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Device</th>
                            <th>Activity ID</th>
                            <th>Route</th>
                            <th>Env</th>
                            <th>Registered At</th>
                            <th>Last Push At</th>
                            <th>Last Push Ago</th>
                            <th>Last App Check-in</th>
                            <th>Expires In</th>
                            <th>Push #</th>
                            <th>Mute On Arrival</th>
                        </tr>
                    </thead>
                    <tbody>${liveActivityRows}</tbody>
                </table>
            </div>
        </section>

        <section class="panel">
            <h2>🔔 Notification &amp; Push Events <span class="panel-count">last ${notifications.length}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Sent At</th>
                            <th>Device</th>
                            <th>Channel</th>
                            <th>Type</th>
                            <th>Route</th>
                            <th>Result</th>
                            <th>Status</th>
                            <th>Error</th>
                            <th>APNS Env</th>
                            <th>Raw</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${notificationRows || `<tr><td class="empty" colspan="10">No notification events found.</td></tr>`}
                    </tbody>
                </table>
            </div>
        </section>

        <section class="panel">
            <h2>📍 Geofence Events <span class="panel-count">last ${geofenceEvents.length} (max 100)</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Received At</th>
                            <th>Event</th>
                            <th>From</th>
                            <th>To</th>
                            <th>Client Timestamp</th>
                            <th>Device</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${geofenceEventRows || `<tr><td class="empty" colspan="6">No geofence events received yet.</td></tr>`}
                    </tbody>
                </table>
            </div>
        </section>

        <section class="panel">
            <h2>🗓️ Scheduled Notification Subscriptions (Redis) <span class="panel-count">${scheduledSubscriptions.length}</span></h2>
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

/** Returns the last 8 chars of an ID to keep tables compact. Full value shown via title= attr. */
function shortId(id) {
    if (!id || typeof id !== 'string') return '—';
    return '…' + id.slice(-8);
}

/**
 * Returns a human-readable relative duration string for the gap between two Date objects.
 * e.g. "2 min ago", "5 s ago", "in 45 s"
 */
function relativeTime(from, to) {
    const diffMs = to - from;
    const abs = Math.abs(diffMs);
    const past = diffMs >= 0;
    let label;
    if (abs < 5000)        label = 'just now';
    else if (abs < 60000)  label = `${Math.round(abs / 1000)} s`;
    else if (abs < 3600000) label = `${Math.round(abs / 60000)} min`;
    else                   label = `${Math.round(abs / 3600000)} hr`;
    if (label === 'just now') return label;
    return past ? `${label} ago` : `in ${label}`;
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
