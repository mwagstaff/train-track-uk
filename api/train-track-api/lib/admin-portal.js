import {
    getLiveActivityPayload,
    getNotificationEvent,
    getNotificationSubscription,
    getDevicePreferences,
    listDevicePreferences,
    listLiveActivityPayloads,
    listNotificationEvents,
    listNotificationSubscriptions,
    listGeofenceEvents
} from './admin-data-store.js';
import { liveActivityManager } from './live-activity-manager.js';
import { LiveActivityPushClient } from './live-activity-push-client.js';
import { getDeviceLastSeen } from './metrics.js';
import { pushToStartTokenStore, pushToStartTokenTtlPolicy } from './push-to-start-token-store.js';

const DEFAULT_LIMIT = 500;
const DEFAULT_NOTIFICATION_LIMIT = 20;
const DEFAULT_DEVICE_PAGE_SIZE = 50;
const DEFAULT_REPLAY_DEVICE_ID = 'BF4D495F-E69A-4E7D-B47D-09930684A323';

export function registerAdminRoutes(app) {
    app.get('/admin', async (req, res) => {
        try {
            const query = typeof req.query?.q === 'string' ? req.query.q.trim() : '';
            const limit = clampLimit(req.query?.limit, 1, 5000, DEFAULT_LIMIT);
            const [subscriptions, notifications, geofenceEvents] = await Promise.all([
                listNotificationSubscriptions({ search: query, limit }),
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

    app.get('/admin/devices', async (req, res) => {
        try {
            const query = typeof req.query?.q === 'string' ? req.query.q.trim() : '';
            const page = clampLimit(req.query?.page, 1, 100000, 1);
            const pageSize = clampLimit(req.query?.per_page, 1, 250, DEFAULT_DEVICE_PAGE_SIZE);
            const [subscriptions, notifications, geofenceEvents, devicePreferences] = await Promise.all([
                listNotificationSubscriptions({ limit: 5000 }),
                listNotificationEvents({ limit: 5000 }),
                listGeofenceEvents(),
                listDevicePreferences()
            ]);
            const liveActivitySessions = liveActivityManager.listSubscriptions();
            const summaries = buildDeviceSummaries({
                subscriptions,
                notifications,
                geofenceEvents,
                liveActivitySessions,
                devicePreferences,
                query
            });
            const total = summaries.length;
            const totalPages = Math.max(1, Math.ceil(total / pageSize));
            const safePage = Math.min(page, totalPages);
            const start = (safePage - 1) * pageSize;
            const devices = summaries.slice(start, start + pageSize);
            res.type('html').send(renderDeviceListPage({
                query,
                devices,
                page: safePage,
                pageSize,
                total,
                totalPages
            }));
        } catch (error) {
            console.error('[admin] Failed to load device list:', error?.message || error);
            res.status(500).type('html').send(renderErrorPage('Failed to load admin device list.'));
        }
    });

    app.get('/admin/devices/:deviceId', async (req, res) => {
        try {
            const deviceId = req.params?.deviceId;
            const [subscriptions, notifications, geofenceEvents, devicePreferences] = await Promise.all([
                listNotificationSubscriptions({ limit: 5000 }),
                listNotificationEvents({ limit: 5000 }),
                listGeofenceEvents(),
                getDevicePreferences(deviceId)
            ]);
            const liveActivitySessions = liveActivityManager.listSubscriptions();
            const detail = buildDeviceDetail({
                deviceId,
                subscriptions,
                notifications,
                geofenceEvents,
                liveActivitySessions,
                devicePreferences
            });
            if (!detail.hasData) {
                return res.status(404).type('html').send(renderErrorPage(`Device not found: ${deviceId}`));
            }
            res.type('html').send(renderDeviceDetailPage(detail));
        } catch (error) {
            console.error('[admin] Failed to load device detail:', error?.message || error);
            res.status(500).type('html').send(renderErrorPage('Failed to load admin device detail.'));
        }
    });

    app.get('/admin/live-activities', async (req, res) => {
        try {
            const query = typeof req.query?.q === 'string' ? req.query.q.trim() : '';
            const page = clampLimit(req.query?.page, 1, 100000, 1);
            const pageSize = clampLimit(req.query?.per_page, 1, 250, 50);
            const [subscriptions, payloads, pushToStartTokens] = await Promise.all([
                listNotificationSubscriptions({ limit: 5000 }),
                listLiveActivityPayloads({ limit: 5000 }),
                pushToStartTokenStore.list({ limit: 5000 })
            ]);
            const liveActivitySessions = liveActivityManager.listSubscriptions();
            const rows = buildLiveActivityAdminRows({
                subscriptions,
                liveActivitySessions,
                payloads,
                pushToStartTokens,
                query
            });
            const pagination = paginateItems(rows, page, pageSize);
            res.type('html').send(renderLiveActivityAdminPage({
                query,
                rows: pagination.items,
                pagination,
                tokenPolicy: pushToStartTokenTtlPolicy
            }));
        } catch (error) {
            console.error('[admin] Failed to load live activities:', error?.message || error);
            res.status(500).type('html').send(renderErrorPage('Failed to load live activities.'));
        }
    });

    app.get('/admin/subscriptions/:id', async (req, res) => {
        try {
            const id = req.params?.id;
            const subscription = await getNotificationSubscription(id);
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

    app.get('/admin/live-activity-payloads', async (req, res) => {
        try {
            const query = typeof req.query?.q === 'string' ? req.query.q.trim() : '';
            const limit = clampLimit(req.query?.limit, 1, 5000, DEFAULT_LIMIT);
            const devicePage = clampLimit(req.query?.device_page, 1, 100000, 1);
            const devicePageSize = clampLimit(req.query?.device_per_page, 1, 100, 20);
            const targetDeviceId = normalizeDeviceId(req.query?.target_device_id) || DEFAULT_REPLAY_DEVICE_ID;
            const [payloads, devicePayloads, pushToStartTokens] = await Promise.all([
                listLiveActivityPayloads({ search: query, limit }),
                listLiveActivityPayloads({ limit: 5000 }),
                pushToStartTokenStore.list({ limit: 500 })
            ]);
            const recentDevices = buildRecentLiveActivityDevices(devicePayloads, pushToStartTokens);
            const devicePagination = paginateItems(recentDevices, devicePage, devicePageSize);
            res.type('html').send(renderLiveActivityPayloadListPage({
                query,
                limit,
                payloads,
                targetDeviceId,
                recentDevices,
                devicePagination,
                replayResult: null
            }));
        } catch (error) {
            console.error('[admin] Failed to load live activity payloads:', error?.message || error);
            res.status(500).type('html').send(renderErrorPage('Failed to load live activity payloads.'));
        }
    });

    app.get('/admin/live-activity-payloads/:id', async (req, res) => {
        try {
            const id = req.params?.id;
            const payload = await getLiveActivityPayload(id);
            if (!payload) {
                return res.status(404).type('html').send(renderErrorPage(`Live Activity payload not found: ${id}`));
            }
            const targetDeviceId = normalizeDeviceId(req.query?.target_device_id) || DEFAULT_REPLAY_DEVICE_ID;
            res.type('html').send(renderLiveActivityPayloadDetailPage({ payload, targetDeviceId, replayResult: null }));
        } catch (error) {
            console.error('[admin] Failed to load live activity payload detail:', error?.message || error);
            res.status(500).type('html').send(renderErrorPage('Failed to load live activity payload detail.'));
        }
    });

    app.post('/admin/live-activity-payloads/:id/replay', async (req, res) => {
        try {
            const id = req.params?.id;
            const payloadRecord = await getLiveActivityPayload(id);
            if (!payloadRecord) {
                return res.status(404).type('html').send(renderErrorPage(`Live Activity payload not found: ${id}`));
            }

            const targetDeviceId = normalizeDeviceId(req.body?.target_device_id) || DEFAULT_REPLAY_DEVICE_ID;
            const targetActivityId = normalizeDeviceId(req.body?.target_activity_id);
            let result;
            let statusCode = 200;
            try {
                result = await replayLiveActivityPayload({
                    payloadRecord,
                    targetDeviceId,
                    targetActivityId
                });
            } catch (error) {
                statusCode = 400;
                result = await buildReplayFailureResult({
                    payloadRecord,
                    targetDeviceId,
                    targetActivityId,
                    error
                });
            }
            res.status(statusCode).type('html').send(renderLiveActivityPayloadDetailPage({
                payload: payloadRecord,
                targetDeviceId,
                targetActivityId,
                replayResult: result
            }));
        } catch (error) {
            console.error('[admin] Failed to replay live activity payload:', error?.message || error);
            res.status(500).type('html').send(renderErrorPage(`Failed to replay live activity payload: ${error?.message || error}`));
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
        const lastSeenTs = getDeviceLastSeen(subscription.deviceId);
        const lastSeenAgeMs = lastSeenTs ? (now - lastSeenTs) : null;
        const lastSeenCell = lastSeenTs
            ? (() => {
                const ago = relativeTime(new Date(lastSeenTs), now);
                const stale = lastSeenAgeMs > 7 * 24 * 60 * 60 * 1000;
                const color = stale ? 'color:#c0392b;font-weight:600' : 'color:#27ae60';
                return `<span style="${color}" title="${new Date(lastSeenTs).toISOString()}">${ago}</span>`;
            })()
            : '<span class="never">—</span>';
        const subId = escapeHtml(subscription.id || '');
        return `
            <tr id="sub-row-${subId}">
                <td>${subId}</td>
                <td>${formatDate(subscription.createdAt)}</td>
                <td class="token">${escapeHtml(subscription.pushToken || '')}</td>
                <td>${subscription.useSandbox ? 'sandbox' : 'prod'}</td>
                <td>${escapeHtml(stationNames)}</td>
                <td>${escapeHtml(scheduleStart)}</td>
                <td>${escapeHtml(scheduleEnd)}</td>
                <td>${escapeHtml(days)}</td>
                <td>${lastSeenCell}</td>
                <td>
                    <a href="admin/subscriptions/${encodeURIComponent(subscription.id || '')}">View JSON</a>
                    &nbsp;
                    <button onclick="deleteSubscription('${subId}')" style="cursor:pointer;background:#e74c3c;color:#fff;border:none;border-radius:4px;padding:2px 8px;font-size:0.8em">Delete</button>
                </td>
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
        .search button, form button {
            border-radius: 8px; padding: 8px 12px; font-size: 13px;
            border: 1px solid var(--accent); background: var(--accent);
            color: #fff; cursor: pointer;
        }
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
            <a href="admin/devices">Device Admin</a>
            <a href="admin/live-activities">Live Activities</a>
            <a href="admin/live-activity-payloads">Payload Replay</a>
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
            <h2>🗓️ Scheduled Notification Subscriptions (Mongo) <span class="panel-count">${scheduledSubscriptions.length}</span></h2>
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
                            <th>Device Last Seen</th>
                            <th>Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${subscriptionRows || `<tr><td class="empty" colspan="10">No subscriptions found.</td></tr>`}
                    </tbody>
                </table>
            </div>
        </section>
    </div>
<script>
async function deleteSubscription(id) {
    if (!confirm('Delete subscription ' + id + '?\\n\\nThis will permanently remove it from Mongo.')) return;
    try {
        const res = await fetch('/api/v2/notifications/debug/subscriptions', {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ subscription_id: id })
        });
        const json = await res.json().catch(() => ({}));
        if (res.ok && json.status !== 'not_found') {
            document.getElementById('sub-row-' + id)?.remove();
        } else {
            alert('Delete failed: ' + (json.error || json.status || res.status));
        }
    } catch (e) {
        alert('Delete failed: ' + e.message);
    }
}
</script>
</body>
</html>`;
}

function renderDeviceListPage({ query, devices, page, pageSize, total, totalPages }) {
    const renderedAt = escapeHtml(new Date().toISOString());
    const qValue = escapeHtml(query || '');
    const prevHref = page > 1 ? deviceListHref({ query, page: page - 1, pageSize }) : null;
    const nextHref = page < totalPages ? deviceListHref({ query, page: page + 1, pageSize }) : null;
    const rows = devices.map((device) => {
        const lastSeen = device.lastSeenAt
            ? `<span title="${escapeHtml(device.lastSeenAt)}">${escapeHtml(relativeTime(new Date(device.lastSeenAt), new Date()))}</span>`
            : '<span class="never">—</span>';
        const href = `devices/${encodeURIComponent(device.deviceId)}`;
        return `<tr>
            <td class="device-id"><a href="${href}">${escapeHtml(device.deviceId)}</a></td>
            <td>${escapeHtml(device.scheduledCount)}</td>
            <td>${escapeHtml(device.notificationEventCount)}</td>
            <td>${escapeHtml(device.liveNotificationCount)}</td>
            <td>${escapeHtml(device.liveActivityCount)}</td>
            <td>${escapeHtml(device.geofenceEventCount)}</td>
            <td>${lastSeen}</td>
            <td>${formatDate(device.latestActivityAt) || '<span class="never">—</span>'}</td>
        </tr>`;
    }).join('');

    return renderAdminShell({
        title: 'Train Track Device Admin',
        body: `
    <div class="wrap">
        <h1>Device Admin</h1>
        <div class="meta">Rendered at ${renderedAt} · ${total} device${total === 1 ? '' : 's'} · Page ${page} of ${totalPages}</div>
        <form class="search" method="GET" action="">
            <input type="text" name="q" value="${qValue}" placeholder="Search device ID, station, route, status, or error text" />
            <input type="hidden" name="per_page" value="${pageSize}" />
            <button type="submit">Search</button>
            <a href="?">Clear</a>
            <a href="../admin">Dashboard</a>
        </form>
        <section class="panel">
            <h2>Devices <span class="panel-count">${devices.length} shown</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Device ID</th>
                            <th>Scheduled Updates</th>
                            <th>Notifications</th>
                            <th>Live Notification Sessions</th>
                            <th>Live Activities</th>
                            <th>Geofence Events</th>
                            <th>Last Seen</th>
                            <th>Latest Activity</th>
                        </tr>
                    </thead>
                    <tbody>${rows || `<tr><td class="empty" colspan="8">No devices found.</td></tr>`}</tbody>
                </table>
            </div>
        </section>
        <nav class="pager">
            ${prevHref ? `<a href="${prevHref}">Previous</a>` : '<span>Previous</span>'}
            <span>Page ${page} of ${totalPages}</span>
            ${nextHref ? `<a href="${nextHref}">Next</a>` : '<span>Next</span>'}
        </nav>
    </div>`
    });
}

function renderDeviceDetailPage(detail) {
    const now = new Date();
    const title = `Device ${detail.deviceId}`;
    const scheduledRows = detail.scheduledSubscriptions.map((subscription) => renderSubscriptionDetailRow(subscription)).join('');
    const liveNotificationRows = detail.liveNotificationSubscriptions.map((subscription) => renderSubscriptionDetailRow(subscription)).join('');
    const notificationRows = detail.notifications.map((event) => renderNotificationDetailRow(event)).join('');
    const liveActivityRows = detail.liveActivitySessions.map((session) => {
        return `<tr>
            <td title="${escapeHtml(session.activityId || '')}">${escapeHtml(shortId(session.activityId))}</td>
            <td>${escapeHtml(session.fromStation || '')}</td>
            <td>${escapeHtml(session.toStation || '')}</td>
            <td>${escapeHtml(session.windowStart || '')}</td>
            <td>${escapeHtml(session.windowEnd || '')}</td>
            <td>${formatDate(session.createdAt)}</td>
            <td>${formatDate(session.lastPushAt) || '<span class="never">—</span>'}</td>
            <td>${formatDate(session.endAt) || '<span class="never">—</span>'}</td>
            <td>${escapeHtml(session.scheduleKey || '')}</td>
            <td>${escapeHtml(session.preferredServiceId || '')}</td>
            <td>${escapeHtml(session.useSandbox ? 'sandbox' : 'prod')}</td>
        </tr>`;
    }).join('');
    const geofenceRows = detail.geofenceEvents.map((event) => {
        return `<tr>
            <td>${formatDate(event.received_at)}</td>
            <td>${escapeHtml(event.event || '')}</td>
            <td>${escapeHtml(event.from || '')}</td>
            <td>${escapeHtml(event.to || '')}</td>
            <td>${formatDate(event.client_timestamp)}</td>
            <td>${escapeHtml(event.region_id || '')}</td>
        </tr>`;
    }).join('');
    const preferenceRows = detail.preferences.map((pref) => `<tr>
        <td>${escapeHtml(pref.name)}</td>
        <td>${escapeHtml(formatPreferenceValue(pref.value))}</td>
        <td>${escapeHtml(pref.source)}</td>
        <td>${formatDate(pref.observedAt) || '<span class="never">—</span>'}</td>
    </tr>`).join('');
    const lastSeen = detail.lastSeenAt ? relativeTime(new Date(detail.lastSeenAt), now) : 'never';

    return renderAdminShell({
        title,
        body: `
    <div class="wrap">
        <a href="../devices">Back to Devices</a>
        <h1>Device ${escapeHtml(detail.deviceId)}</h1>
        <div class="meta">Last seen: ${escapeHtml(lastSeen)}${detail.lastSeenAt ? ` · ${escapeHtml(detail.lastSeenAt)}` : ''}</div>

        <section class="panel">
            <h2>Scheduled Journey Updates <span class="panel-count">${detail.scheduledSubscriptions.length}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>ID</th>
                            <th>Created</th>
                            <th>Updated</th>
                            <th>Start Station</th>
                            <th>End Station</th>
                            <th>Window Start</th>
                            <th>Window End</th>
                            <th>Days</th>
                            <th>Notification Types</th>
                            <th>Env</th>
                            <th>Raw</th>
                        </tr>
                    </thead>
                    <tbody>${scheduledRows || `<tr><td class="empty" colspan="11">No scheduled journey updates for this device.</td></tr>`}</tbody>
                </table>
            </div>
        </section>

        <section class="panel">
            <h2>Associated Notifications <span class="panel-count">${detail.notifications.length}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Sent At</th>
                            <th>Type</th>
                            <th>Channel</th>
                            <th>Start Station</th>
                            <th>End Station</th>
                            <th>Window Start</th>
                            <th>Window End</th>
                            <th>Schedule Key</th>
                            <th>Result</th>
                            <th>Status</th>
                            <th>Error</th>
                            <th>Env</th>
                            <th>Raw</th>
                        </tr>
                    </thead>
                    <tbody>${notificationRows || `<tr><td class="empty" colspan="13">No notification events for this device.</td></tr>`}</tbody>
                </table>
            </div>
        </section>

        <section class="panel">
            <h2>User Preferences <span class="panel-count">${detail.preferences.length}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Preference</th>
                            <th>Value</th>
                            <th>Source</th>
                            <th>Observed At</th>
                        </tr>
                    </thead>
                    <tbody>${preferenceRows || `<tr><td class="empty" colspan="4">No server-observed preferences for this device.</td></tr>`}</tbody>
                </table>
            </div>
        </section>

        <section class="panel">
            <h2>Live Notification Sessions <span class="panel-count">${detail.liveNotificationSubscriptions.length}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>ID</th>
                            <th>Created</th>
                            <th>Updated</th>
                            <th>Start Station</th>
                            <th>End Station</th>
                            <th>Window Start</th>
                            <th>Window End</th>
                            <th>Days</th>
                            <th>Notification Types</th>
                            <th>Env</th>
                            <th>Raw</th>
                        </tr>
                    </thead>
                    <tbody>${liveNotificationRows || `<tr><td class="empty" colspan="11">No live notification sessions for this device.</td></tr>`}</tbody>
                </table>
            </div>
        </section>

        <section class="panel">
            <h2>Live Activities <span class="panel-count">${detail.liveActivitySessions.length}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Activity ID</th>
                            <th>Start Station</th>
                            <th>End Station</th>
                            <th>Window Start</th>
                            <th>Window End</th>
                            <th>Created</th>
                            <th>Last Push</th>
                            <th>Ends</th>
                            <th>Schedule Key</th>
                            <th>Preferred Service</th>
                            <th>Env</th>
                        </tr>
                    </thead>
                    <tbody>${liveActivityRows || `<tr><td class="empty" colspan="11">No active live activities for this device.</td></tr>`}</tbody>
                </table>
            </div>
        </section>

        <section class="panel">
            <h2>Geofence Events <span class="panel-count">${detail.geofenceEvents.length}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Received At</th>
                            <th>Event</th>
                            <th>Start Station</th>
                            <th>End Station</th>
                            <th>Client Timestamp</th>
                            <th>Region ID</th>
                        </tr>
                    </thead>
                    <tbody>${geofenceRows || `<tr><td class="empty" colspan="6">No geofence events for this device.</td></tr>`}</tbody>
                </table>
            </div>
        </section>
    </div>`
    });
}

function renderLiveActivityAdminPage({ query, rows, pagination, tokenPolicy }) {
    const renderedAt = escapeHtml(new Date().toISOString());
    const qValue = escapeHtml(query || '');
    const prevHref = pagination.page > 1
        ? liveActivityAdminHref({ query, page: pagination.page - 1, pageSize: pagination.pageSize })
        : null;
    const nextHref = pagination.page < pagination.totalPages
        ? liveActivityAdminHref({ query, page: pagination.page + 1, pageSize: pagination.pageSize })
        : null;
    const rowHtml = rows.map((row) => renderLiveActivityAdminRow(row)).join('');
    const ttlPolicy = tokenPolicy?.minimumTtlSeconds
        ? formatDurationSeconds(tokenPolicy.minimumTtlSeconds)
        : '90 days';
    const refreshPolicy = tokenPolicy?.ttlSeconds
        ? formatDurationSeconds(tokenPolicy.ttlSeconds)
        : ttlPolicy;

    return renderAdminShell({
        title: 'Train Track Live Activities',
        body: `
    <div class="wrap">
        <a href="../admin">Back to Admin</a>
        <h1>Live Activities</h1>
        <div class="meta">Rendered at ${renderedAt} · Push-to-start token policy: ${escapeHtml(refreshPolicy)} logical TTL, refreshed whenever the app reposts the token · Page ${pagination.page} of ${pagination.totalPages}</div>
        <form class="search" method="GET" action="">
            <input type="text" name="q" value="${qValue}" placeholder="Search device, activity, route, event, schedule key, token, or TTL status" />
            <input type="hidden" name="per_page" value="${escapeHtml(pagination.pageSize)}" />
            <button type="submit">Search</button>
            <a href="?">Clear</a>
            <a href="live-activity-payloads">Payload Replay</a>
        </form>
        <section class="panel">
            <h2>User Live Activities <span class="panel-count">${pagination.totalItems}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Device</th>
                            <th>Activity</th>
                            <th>Source</th>
                            <th>Event</th>
                            <th>Route</th>
                            <th>Schedule Key</th>
                            <th>Recorded / Created</th>
                            <th>Last Push</th>
                            <th>Env</th>
                            <th>Push-to-start Token</th>
                            <th>Token Updated</th>
                            <th>Token TTL</th>
                            <th>Raw</th>
                        </tr>
                    </thead>
                    <tbody>${rowHtml || `<tr><td class="empty" colspan="13">No live activities found.</td></tr>`}</tbody>
                </table>
            </div>
        </section>
        <nav class="pager">
            ${prevHref ? `<a href="${prevHref}">Previous</a>` : '<span>Previous</span>'}
            <span>Page ${pagination.page} of ${pagination.totalPages}</span>
            ${nextHref ? `<a href="${nextHref}">Next</a>` : '<span>Next</span>'}
        </nav>
    </div>`
    });
}

function renderLiveActivityAdminRow(row) {
    const token = row.pushToStartToken;
    const tokenCell = token
        ? `<span class="token" title="${escapeHtml(token.deviceId || '')}">${escapeHtml(token.token || '')}</span>`
        : '<span class="badge badge-err">missing</span>';
    const tokenEnv = token
        ? ` <span class="badge ${token.useSandbox ? 'badge-sandbox' : 'badge-prod'}">${token.useSandbox ? 'sandbox' : 'prod'}</span>`
        : '';
    return `<tr>
        <td class="device-id"><a href="devices/${encodeURIComponent(row.deviceId || '')}">${escapeHtml(row.deviceId || '')}</a></td>
        <td title="${escapeHtml(row.activityId || '')}">${escapeHtml(shortId(row.activityId))}</td>
        <td>${escapeHtml(row.source || '')}</td>
        <td>${escapeHtml(row.event || '')}</td>
        <td><strong>${escapeHtml(row.route || '')}</strong></td>
        <td>${escapeHtml(row.scheduleKey || '')}</td>
        <td>${formatDate(row.recordedAt) || '<span class="never">—</span>'}</td>
        <td>${formatDate(row.lastPushAt) || '<span class="never">—</span>'}</td>
        <td>${escapeHtml(row.environment || '')}</td>
        <td>${tokenCell}${tokenEnv}</td>
        <td>${formatDate(token?.updatedAt) || '<span class="never">—</span>'}</td>
        <td>${formatPushToStartTtl(token)}</td>
        <td>${row.rawHref ? `<a href="${escapeHtml(row.rawHref)}">JSON</a>` : '<span class="never">—</span>'}</td>
    </tr>`;
}

function renderLiveActivityPayloadListPage({ query, limit, payloads, targetDeviceId, recentDevices = [], devicePagination, replayResult }) {
    const renderedAt = escapeHtml(new Date().toISOString());
    const rows = payloads.map((record) => renderLiveActivityPayloadRow(record, targetDeviceId)).join('');
    const deviceRows = (devicePagination?.items || [])
        .map((device) => renderRecentLiveActivityDeviceRow(device, query, limit))
        .join('');
    const devicePager = renderDevicePager({ pagination: devicePagination, query, limit, targetDeviceId });
    const replayBlock = replayResult ? renderReplayResult(replayResult) : '';
    return renderAdminShell({
        title: 'Live Activity Payload Replay',
        body: `
    <div class="wrap">
        <a href="../admin">Back to Admin</a>
        <h1>Live Activity Payload Replay</h1>
        <div class="meta">Rendered at ${renderedAt} · Payloads retained for 7 days · Default target ${escapeHtml(DEFAULT_REPLAY_DEVICE_ID)}</div>
        ${replayBlock}
        <form class="search" method="GET" action="">
            <input type="text" name="q" value="${escapeHtml(query || '')}" placeholder="Search payloads by route, device, APNs status, event, or schedule key" />
            <input type="text" name="target_device_id" value="${escapeHtml(targetDeviceId || DEFAULT_REPLAY_DEVICE_ID)}" placeholder="Target test device ID" />
            <input type="hidden" name="limit" value="${escapeHtml(limit)}" />
            <button type="submit">Search</button>
            <a href="?target_device_id=${encodeURIComponent(DEFAULT_REPLAY_DEVICE_ID)}">Reset</a>
        </form>
        <section class="panel">
            <h2>Recent Device IDs <span class="panel-count">${recentDevices.length}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Device ID</th>
                            <th>Last Seen</th>
                            <th>Source</th>
                            <th>Payloads</th>
                            <th>Last Event</th>
                            <th>Push-to-start</th>
                        </tr>
                    </thead>
                    <tbody>${deviceRows || `<tr><td class="empty" colspan="6">No recent live activity devices found.</td></tr>`}</tbody>
                </table>
            </div>
            ${devicePager}
        </section>
        <section class="panel">
            <h2>Historical Live Activity Payloads <span class="panel-count">${payloads.length}</span></h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Recorded</th>
                            <th>Event</th>
                            <th>Route</th>
                            <th>Schedule Key</th>
                            <th>Reason</th>
                            <th>Env</th>
                            <th>Status</th>
                            <th>Replay</th>
                            <th>Raw</th>
                        </tr>
                    </thead>
                    <tbody>${rows || `<tr><td class="empty" colspan="9">No live activity payloads found.</td></tr>`}</tbody>
                </table>
            </div>
        </section>
    </div>`
    });
}

function renderLiveActivityPayloadDetailPage({ payload, targetDeviceId, targetActivityId = '', replayResult }) {
    const event = payload?.event || payload?.payload?.aps?.event || '';
    const reason = payload?.context?.end_reason || payload?.context?.reason || '';
    const isStartPayload = payload?.payload?.aps?.event === 'start';
    const activityInputDisabled = isStartPayload ? ' disabled' : '';
    const activityInputValue = isStartPayload ? '' : targetActivityId;
    const activityInputPlaceholder = isStartPayload
        ? 'Not used for start payloads'
        : 'Target activity ID for update/end payloads';
    const replayHelp = isStartPayload
        ? 'Start replay uses the target device push-to-start token. Leave Target activity ID blank.'
        : 'Update/end replay uses an active Live Activity update token. Leave Target activity ID blank to use the latest active activity for that device.';
    return renderAdminShell({
        title: `Live Activity Payload ${payload?.id || ''}`,
        body: `
    <div class="wrap">
        <a href="?target_device_id=${encodeURIComponent(targetDeviceId || DEFAULT_REPLAY_DEVICE_ID)}" onclick="this.href = window.location.pathname.replace(/\\/replay\\/?$/, '').replace(/\\/[^/]+\\/?$/, '') + '?target_device_id=${encodeURIComponent(targetDeviceId || DEFAULT_REPLAY_DEVICE_ID)}'">Back to Payload Replay</a>
        <h1>Live Activity Payload ${escapeHtml(payload?.id || '')}</h1>
        <div class="meta">Event: ${escapeHtml(event)} · Reason: ${escapeHtml(reason || 'n/a')} · Recorded: ${formatDate(payload?.recorded_at) || '<span class="never">—</span>'}</div>
        ${replayResult ? renderReplayResult(replayResult) : ''}
        <section class="panel">
            <h2>Replay</h2>
            <form class="search" method="POST" action="replay" onsubmit="this.action = window.location.pathname.replace(/\\/replay\\/?$/, '').replace(/\\/$/, '') + '/replay'">
                <input type="text" name="target_device_id" value="${escapeHtml(targetDeviceId || DEFAULT_REPLAY_DEVICE_ID)}" placeholder="Target test device ID" />
                <input type="text" name="target_activity_id" value="${escapeHtml(activityInputValue || '')}" placeholder="${escapeHtml(activityInputPlaceholder)}"${activityInputDisabled} />
                <button type="submit">Replay Payload</button>
            </form>
            <div class="meta" style="padding:0 16px 14px;margin:0">${escapeHtml(replayHelp)}</div>
        </section>
        <section class="panel">
            <h2>Raw Payload Record</h2>
            <pre class="json">${escapeHtml(JSON.stringify(payload, null, 2))}</pre>
        </section>
    </div>`
    });
}

function renderRecentLiveActivityDeviceRow(device, query, limit) {
    const deviceId = device.deviceId || '';
    const params = new URLSearchParams({
        target_device_id: deviceId,
        q: deviceId,
        limit: String(limit || DEFAULT_LIMIT)
    });
    const source = Array.from(device.sources || []).sort().join(', ');
    const pushToken = device.pushToStartTokenUpdatedAt
        ? `${device.pushToStartUseSandbox ? 'sandbox' : 'prod'} · ${formatDate(device.pushToStartTokenUpdatedAt)}`
        : '';
    return `<tr>
        <td class="device-id"><a href="?${escapeHtml(params.toString())}">${escapeHtml(deviceId)}</a></td>
        <td>${formatDate(device.lastSeenAt)}</td>
        <td>${escapeHtml(source)}</td>
        <td>${escapeHtml(device.payloadCount || 0)}</td>
        <td>${escapeHtml(device.lastEvent || '')}</td>
        <td>${escapeHtml(pushToken)}</td>
    </tr>`;
}

function renderDevicePager({ pagination, query, limit, targetDeviceId }) {
    if (!pagination || pagination.totalPages <= 1) {
        return '';
    }
    const makeHref = (page) => {
        const params = new URLSearchParams();
        if (query) params.set('q', query);
        params.set('target_device_id', targetDeviceId || DEFAULT_REPLAY_DEVICE_ID);
        params.set('limit', String(limit || DEFAULT_LIMIT));
        params.set('device_page', String(page));
        params.set('device_per_page', String(pagination.pageSize));
        return `?${params.toString()}`;
    };
    const prev = pagination.page > 1
        ? `<a href="${escapeHtml(makeHref(pagination.page - 1))}">Previous devices</a>`
        : '<span>Previous devices</span>';
    const next = pagination.page < pagination.totalPages
        ? `<a href="${escapeHtml(makeHref(pagination.page + 1))}">Next devices</a>`
        : '<span>Next devices</span>';
    return `<div class="pager" style="padding:12px 16px;border-top:1px solid var(--line)">
        ${prev}
        <span>Page ${pagination.page} of ${pagination.totalPages}</span>
        ${next}
    </div>`;
}

function renderLiveActivityPayloadRow(record, targetDeviceId) {
    const contentState = record?.payload?.aps?.['content-state'] || {};
    const route = contentState.routeTitle || `${contentState.fromCRS || ''} → ${contentState.toCRS || ''}`;
    const scheduleKey = contentState.scheduleKey || record?.context?.schedule_key || '';
    const reason = record?.context?.end_reason || record?.context?.reason || '';
    const status = record?.response?.status ?? record?.response?.reason ?? '';
    return `<tr>
        <td>${formatDate(record.recorded_at)}</td>
        <td>${escapeHtml(record.event || record?.payload?.aps?.event || '')}</td>
        <td>${escapeHtml(route)}</td>
        <td>${escapeHtml(scheduleKey)}</td>
        <td>${escapeHtml(reason)}</td>
        <td>${escapeHtml(record.environment || '')}</td>
        <td>${escapeHtml(formatStatus(status))}</td>
        <td>
            <form method="POST" action="live-activity-payloads/${encodeURIComponent(record.id || '')}/replay" style="display:flex;gap:6px;align-items:center;flex-wrap:wrap">
                <input type="hidden" name="target_device_id" value="${escapeHtml(targetDeviceId || DEFAULT_REPLAY_DEVICE_ID)}" />
                <button type="submit">Replay</button>
            </form>
        </td>
        <td><a href="live-activity-payloads/${encodeURIComponent(record.id || '')}?target_device_id=${encodeURIComponent(targetDeviceId || DEFAULT_REPLAY_DEVICE_ID)}">JSON</a></td>
    </tr>`;
}

function renderReplayResult(result) {
    const ok = result?.success ? 'badge-ok' : 'badge-err';
    return `<section class="panel">
        <h2>Replay Result <span class="badge ${ok}">${result?.success ? 'sent' : 'failed'}</span></h2>
        <pre class="json">${escapeHtml(JSON.stringify(result, null, 2))}</pre>
    </section>`;
}

async function replayLiveActivityPayload({ payloadRecord, targetDeviceId, targetActivityId }) {
    const payload = payloadRecord?.payload;
    if (!payload?.aps?.event) {
        throw new Error('Stored payload is missing aps.event');
    }

    const event = payload.aps.event;
    const client = new LiveActivityPushClient();
    let tokenRecord = null;
    let token = null;
    let useSandbox = payloadRecord?.environment === 'sandbox';

    if (event === 'start') {
        tokenRecord = await pushToStartTokenStore.get(targetDeviceId);
        token = tokenRecord?.pushToStartToken || null;
        useSandbox = tokenRecord?.useSandbox === true;
    } else {
        const subscription = targetActivityId
            ? liveActivityManager.getSubscription(targetDeviceId, targetActivityId)
            : liveActivityManager.getLatestSubscriptionForDevice(targetDeviceId);
        token = subscription?.pushToken || null;
        useSandbox = subscription?.useSandbox === true;
        tokenRecord = subscription ? {
            activityId: subscription.activityId,
            route: `${subscription.fromStation || ''}-${subscription.toStation || ''}`
        } : null;
    }

    if (!token) {
        throw new Error(event === 'start'
            ? `No push-to-start token found for device ${targetDeviceId}`
            : `No live activity update token found for device ${targetDeviceId}`);
    }

    const response = await client.sendLiveActivityUpdate(token, payload, {
        useSandbox,
        event: `replay_${event}`,
        replayedFromId: payloadRecord.id,
        context: {
            replay: true,
            replayed_from_id: payloadRecord.id,
            target_device_id: targetDeviceId,
            target_activity_id: targetActivityId || null,
            original_context: payloadRecord.context || null
        }
    });

    const success = typeof response?.status === 'number' && response.status >= 200 && response.status < 300;
    return {
        success,
        event,
        target_device_id: targetDeviceId,
        target_activity_id: targetActivityId || tokenRecord?.activityId || null,
        use_sandbox: useSandbox,
        token_source: event === 'start' ? 'push_to_start' : 'live_activity_session',
        token_record: tokenRecord,
        response
    };
}

async function buildReplayFailureResult({ payloadRecord, targetDeviceId, targetActivityId, error }) {
    const event = payloadRecord?.payload?.aps?.event || null;
    const result = {
        success: false,
        event,
        target_device_id: targetDeviceId,
        target_activity_id: targetActivityId || null,
        error: error?.message || String(error)
    };
    if (event === 'start') {
        result.token_source = 'push_to_start';
        result.available_push_to_start_tokens = await pushToStartTokenStore.list({ limit: 20 });
        result.hint = 'Start payload replay needs a current push-to-start token for the target device. Open the app on that device with Live Activities enabled, or replay against one of the listed devices.';
    } else if (event) {
        result.token_source = 'live_activity_session';
        result.hint = 'Update/end payload replay needs an active Live Activity update token for the target device. Start a Live Activity first, then replay update/end payloads against that activity.';
    }
    return result;
}

function renderSubscriptionDetailRow(subscription) {
    const legs = Array.isArray(subscription.legs) ? subscription.legs.filter((leg) => leg && leg.enabled !== false) : [];
    const firstLeg = legs[0] || {};
    const extraLegs = legs.length > 1 ? ` +${legs.length - 1}` : '';
    return `<tr>
        <td title="${escapeHtml(subscription.id || '')}">${escapeHtml(shortId(subscription.id))}</td>
        <td>${formatDate(subscription.createdAt)}</td>
        <td>${formatDate(subscription.updatedAt)}</td>
        <td>${escapeHtml(formatStation(firstLeg, 'from'))}${escapeHtml(extraLegs)}</td>
        <td>${escapeHtml(formatStation(firstLeg, 'to'))}${escapeHtml(extraLegs)}</td>
        <td>${escapeHtml(formatLegSchedule(legs, 'windowStart'))}</td>
        <td>${escapeHtml(formatLegSchedule(legs, 'windowEnd'))}</td>
        <td>${escapeHtml(formatDays(subscription.daysOfWeek))}</td>
        <td>${escapeHtml(formatList(subscription.notificationTypes))}</td>
        <td>${escapeHtml(subscription.useSandbox ? 'sandbox' : 'prod')}</td>
        <td><a href="../subscriptions/${encodeURIComponent(subscription.id || '')}">JSON</a></td>
    </tr>`;
}

function renderNotificationDetailRow(event) {
    const successCell = event.success
        ? '<span class="badge badge-ok">ok</span>'
        : '<span class="badge badge-err">fail</span>';
    const payload = event.payload && typeof event.payload === 'object' ? event.payload : {};
    return `<tr>
        <td>${formatDate(event.sent_at)}</td>
        <td>${escapeHtml(event.type || '')}</td>
        <td>${escapeHtml(event.channel || '')}</td>
        <td>${escapeHtml(event.from_station || payload.from_name || payload.from || event.metadata?.from_station || '')}</td>
        <td>${escapeHtml(event.to_station || payload.to_name || payload.to || event.metadata?.to_station || '')}</td>
        <td>${escapeHtml(payload.window_start || event.metadata?.window_start || '')}</td>
        <td>${escapeHtml(payload.window_end || event.metadata?.window_end || '')}</td>
        <td>${escapeHtml(event.metadata?.schedule_key || payload.leg_key || event.route_key || '')}</td>
        <td>${successCell}</td>
        <td>${escapeHtml(formatStatus(event.status))}</td>
        <td>${escapeHtml(event.error || '')}</td>
        <td>${escapeHtml(event.apns_environment || '')}</td>
        <td><a href="../notifications/${encodeURIComponent(event.id || '')}">JSON</a></td>
    </tr>`;
}

function renderAdminShell({ title, body }) {
    return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapeHtml(title)}</title>
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
        h1 { margin: 8px 0 4px; font-size: 28px; }
        a { color: var(--accent); text-decoration: none; }
        .meta { color: var(--muted); margin-bottom: 18px; font-size: 13px; }
        .search { display: flex; gap: 8px; margin-bottom: 18px; flex-wrap: wrap; }
        .search input {
            min-width: 260px; flex: 1; max-width: 460px;
            border: 1px solid var(--line); border-radius: 8px;
            padding: 10px 12px; font-size: 14px; background: #fff;
        }
        .search button, .search a, .pager a, .pager span {
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
        .device-id { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; word-break: break-all; }
        .token { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; word-break: break-all; }
        .empty { padding: 16px; color: var(--muted); }
        .never { color: #999; font-style: italic; }
        .badge {
            display: inline-block; border-radius: 6px; padding: 2px 7px;
            font-size: 11px; font-weight: 600; white-space: nowrap;
        }
        .badge-ok { background:#d4f5e2; color:#0d6632; }
        .badge-err { background:#fde8e8; color:#b91c1c; }
        .badge-warn { background:#fef3c7; color:#92400e; }
        .badge-sandbox { background:#fef3c7; color:#92400e; }
        .badge-prod { background:#dbeafe; color:#1e40af; }
        .pager { display: flex; gap: 8px; align-items: center; justify-content: center; }
        .pager span { color: var(--muted); cursor: default; }
        .json {
            margin: 0; padding: 16px; overflow: auto;
            font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            font-size: 12px; line-height: 1.45; background: #fff;
        }
    </style>
</head>
<body>${body}</body>
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

function buildDeviceSummaries({ subscriptions = [], notifications = [], geofenceEvents = [], liveActivitySessions = [], devicePreferences = [], query = '' }) {
    const devices = new Map();
    const normalizedQuery = typeof query === 'string' ? query.trim().toLowerCase() : '';

    const ensure = (deviceId) => {
        const normalized = typeof deviceId === 'string' ? deviceId.trim() : '';
        if (!normalized) return null;
        if (!devices.has(normalized)) {
            const lastSeenTs = getDeviceLastSeen(normalized);
            devices.set(normalized, {
                deviceId: normalized,
                scheduledCount: 0,
                liveNotificationCount: 0,
                notificationEventCount: 0,
                liveActivityCount: 0,
                geofenceEventCount: 0,
                lastSeenAt: Number.isFinite(lastSeenTs) ? new Date(lastSeenTs).toISOString() : null,
                latestActivityAt: null,
                searchable: normalized.toLowerCase()
            });
        }
        return devices.get(normalized);
    };

    for (const sub of subscriptions) {
        const entry = ensure(sub?.deviceId);
        if (!entry) continue;
        if (sub?.source === 'live_session') entry.liveNotificationCount += 1;
        else entry.scheduledCount += 1;
        entry.latestActivityAt = latestIso(entry.latestActivityAt, sub?.updatedAt, sub?.createdAt, sub?.lastActiveAt);
        entry.searchable += ` ${JSON.stringify(sub).toLowerCase()}`;
    }

    for (const event of notifications) {
        const entry = ensure(event?.device_id);
        if (!entry) continue;
        entry.notificationEventCount += 1;
        entry.latestActivityAt = latestIso(entry.latestActivityAt, event?.sent_at);
        entry.searchable += ` ${JSON.stringify(event).toLowerCase()}`;
    }

    for (const event of geofenceEvents) {
        const entry = ensure(event?.device_id);
        if (!entry) continue;
        entry.geofenceEventCount += 1;
        entry.latestActivityAt = latestIso(entry.latestActivityAt, event?.received_at, event?.client_timestamp);
        entry.searchable += ` ${JSON.stringify(event).toLowerCase()}`;
    }

    for (const session of liveActivitySessions) {
        const entry = ensure(session?.deviceId);
        if (!entry) continue;
        entry.liveActivityCount += 1;
        entry.latestActivityAt = latestIso(entry.latestActivityAt, session?.lastPushAt, session?.tokenUpdatedAt, session?.createdAt);
        entry.searchable += ` ${JSON.stringify(session).toLowerCase()}`;
    }

    for (const prefs of devicePreferences) {
        const entry = ensure(prefs?.device_id);
        if (!entry) continue;
        entry.latestActivityAt = latestIso(entry.latestActivityAt, prefs?.updated_at);
        entry.searchable += ` ${JSON.stringify(prefs).toLowerCase()}`;
    }

    return Array.from(devices.values())
        .filter((device) => !normalizedQuery || device.searchable.includes(normalizedQuery))
        .sort((left, right) => {
            const leftTime = Date.parse(left.latestActivityAt || left.lastSeenAt || '') || 0;
            const rightTime = Date.parse(right.latestActivityAt || right.lastSeenAt || '') || 0;
            return rightTime - leftTime || left.deviceId.localeCompare(right.deviceId);
        });
}

function buildDeviceDetail({ deviceId, subscriptions = [], notifications = [], geofenceEvents = [], liveActivitySessions = [], devicePreferences = null }) {
    const normalizedDeviceId = typeof deviceId === 'string' ? deviceId.trim() : '';
    const deviceSubscriptions = subscriptions.filter((sub) => sub?.deviceId === normalizedDeviceId);
    const scheduledSubscriptions = deviceSubscriptions.filter((sub) => sub?.source !== 'live_session');
    const liveNotificationSubscriptions = deviceSubscriptions.filter((sub) => sub?.source === 'live_session');
    const deviceNotifications = notifications
        .filter((event) => event?.device_id === normalizedDeviceId)
        .sort((left, right) => (Date.parse(right?.sent_at || '') || 0) - (Date.parse(left?.sent_at || '') || 0));
    const deviceGeofenceEvents = geofenceEvents
        .filter((event) => event?.device_id === normalizedDeviceId)
        .sort((left, right) => (Date.parse(right?.received_at || '') || 0) - (Date.parse(left?.received_at || '') || 0));
    const deviceLiveActivitySessions = liveActivitySessions
        .filter((session) => session?.deviceId === normalizedDeviceId)
        .sort((left, right) => (Date.parse(right?.createdAt || '') || 0) - (Date.parse(left?.createdAt || '') || 0));
    const lastSeenTs = getDeviceLastSeen(normalizedDeviceId);

    return {
        deviceId: normalizedDeviceId,
        scheduledSubscriptions,
        liveNotificationSubscriptions,
        notifications: deviceNotifications,
        geofenceEvents: deviceGeofenceEvents,
        liveActivitySessions: deviceLiveActivitySessions,
        preferences: collectDevicePreferences({
            scheduledSubscriptions,
            liveNotificationSubscriptions,
            liveActivitySessions: deviceLiveActivitySessions,
            devicePreferences
        }),
        lastSeenAt: Number.isFinite(lastSeenTs) ? new Date(lastSeenTs).toISOString() : null,
        hasData: deviceSubscriptions.length > 0
            || deviceNotifications.length > 0
            || deviceGeofenceEvents.length > 0
            || deviceLiveActivitySessions.length > 0
            || Boolean(devicePreferences)
    };
}

function buildLiveActivityAdminRows({ subscriptions = [], liveActivitySessions = [], payloads = [], pushToStartTokens = [], query = '' }) {
    const normalizedQuery = typeof query === 'string' ? query.trim().toLowerCase() : '';
    const tokensByDevice = new Map();
    for (const token of Array.isArray(pushToStartTokens) ? pushToStartTokens : []) {
        const deviceId = normalizeDeviceId(token?.deviceId);
        if (deviceId) tokensByDevice.set(deviceId, token);
    }

    const rows = [];
    const devicesWithActivities = new Set();
    for (const subscription of Array.isArray(subscriptions) ? subscriptions : []) {
        if (subscription?.source === 'live_session') continue;
        const deviceId = normalizeDeviceId(subscription?.deviceId);
        if (!deviceId) continue;
        const legs = Array.isArray(subscription?.legs) ? subscription.legs.filter((leg) => leg && leg.enabled !== false) : [];
        for (const leg of legs) {
            const from = leg?.fromName || leg?.from || '';
            const to = leg?.toName || leg?.to || '';
            const scheduleKey = `${leg?.from || ''}-${leg?.to || ''}|${leg?.windowStart || ''}|${leg?.windowEnd || ''}`;
            const row = {
                id: `scheduled:${subscription?.id || ''}:${scheduleKey}`,
                source: 'scheduled update',
                event: 'scheduled_leg',
                deviceId,
                activityId: '',
                route: `${from || '?'} → ${to || '?'}`,
                scheduleKey,
                recordedAt: subscription?.updatedAt || subscription?.createdAt || null,
                lastPushAt: null,
                latestAt: subscription?.updatedAt || subscription?.createdAt || null,
                environment: subscription?.useSandbox ? 'sandbox' : 'prod',
                rawHref: `subscriptions/${encodeURIComponent(subscription?.id || '')}`,
                pushToStartToken: tokensByDevice.get(deviceId) || null,
                searchable: ''
            };
            row.searchable = `${JSON.stringify(row)} ${JSON.stringify(subscription)}`.toLowerCase();
            rows.push(row);
            devicesWithActivities.add(deviceId);
        }
    }

    for (const session of Array.isArray(liveActivitySessions) ? liveActivitySessions : []) {
        const deviceId = normalizeDeviceId(session?.deviceId);
        if (!deviceId) continue;
        devicesWithActivities.add(deviceId);
        const row = {
            id: `active:${deviceId}:${session?.activityId || ''}`,
            source: 'active session',
            event: 'live_activity_session',
            deviceId,
            activityId: session?.activityId || '',
            route: `${session?.fromStation || '?'} → ${session?.toStation || '?'}`,
            scheduleKey: session?.scheduleKey || '',
            recordedAt: session?.createdAt || null,
            lastPushAt: session?.lastPushAt || null,
            latestAt: latestIso(session?.lastPushAt, session?.tokenUpdatedAt, session?.createdAt),
            environment: session?.useSandbox ? 'sandbox' : 'prod',
            rawHref: null,
            pushToStartToken: tokensByDevice.get(deviceId) || null,
            searchable: ''
        };
        row.searchable = JSON.stringify(row).toLowerCase();
        rows.push(row);
    }

    for (const payload of Array.isArray(payloads) ? payloads : []) {
        const contentState = payload?.payload?.aps?.['content-state'] || {};
        const context = payload?.context || {};
        const deviceId = normalizeDeviceId(
            context.device_id
            || context.target_device_id
            || payload?.device_id
            || contentState.deviceID
            || contentState.deviceId
        );
        if (!deviceId) continue;
        devicesWithActivities.add(deviceId);
        const from = contentState.fromCRS || context.from_station || context.from || '';
        const to = contentState.toCRS || context.to_station || context.to || '';
        const route = contentState.routeTitle || context.route_title || (from || to ? `${from} → ${to}` : '');
        const row = {
            id: payload?.id || '',
            source: 'payload log',
            event: payload?.event || payload?.payload?.aps?.event || '',
            deviceId,
            activityId: context.activity_id || payload?.activity_id || contentState.activityID || contentState.activityId || '',
            route,
            scheduleKey: contentState.scheduleKey || context.schedule_key || '',
            recordedAt: payload?.recorded_at || payload?.sent_at || null,
            lastPushAt: payload?.recorded_at || payload?.sent_at || null,
            latestAt: payload?.recorded_at || payload?.sent_at || null,
            environment: payload?.environment || context.environment || '',
            rawHref: `live-activity-payloads/${encodeURIComponent(payload?.id || '')}`,
            pushToStartToken: tokensByDevice.get(deviceId) || null,
            searchable: ''
        };
        row.searchable = `${JSON.stringify(row)} ${JSON.stringify(payload)}`.toLowerCase();
        rows.push(row);
    }

    for (const [deviceId, token] of tokensByDevice.entries()) {
        if (devicesWithActivities.has(deviceId)) continue;
        const row = {
            id: `push-to-start:${deviceId}`,
            source: 'push-to-start token',
            event: 'token_present',
            deviceId,
            activityId: '',
            route: '',
            scheduleKey: '',
            recordedAt: token?.updatedAt || null,
            lastPushAt: null,
            latestAt: token?.updatedAt || null,
            environment: token?.useSandbox ? 'sandbox' : 'prod',
            rawHref: null,
            pushToStartToken: token,
            searchable: ''
        };
        row.searchable = JSON.stringify(row).toLowerCase();
        rows.push(row);
    }

    return rows
        .filter((row) => !normalizedQuery || row.searchable.includes(normalizedQuery))
        .sort((left, right) => {
            const leftTime = Date.parse(left.latestAt || left.recordedAt || '') || 0;
            const rightTime = Date.parse(right.latestAt || right.recordedAt || '') || 0;
            return rightTime - leftTime
                || String(left.deviceId).localeCompare(String(right.deviceId))
                || String(left.activityId).localeCompare(String(right.activityId));
        });
}

function collectDevicePreferences({ scheduledSubscriptions = [], liveNotificationSubscriptions = [], liveActivitySessions = [], devicePreferences = null }) {
    const preferences = new Map();
    const add = (name, value, source, observedAt) => {
        if (value === undefined || value === null || value === '') return;
        const existing = preferences.get(name);
        const nextTime = Date.parse(observedAt || '') || 0;
        const existingTime = Date.parse(existing?.observedAt || '') || 0;
        if (!existing || nextTime >= existingTime) {
            preferences.set(name, { name, value, source, observedAt: observedAt || null });
        }
    };

    for (const sub of [...scheduledSubscriptions, ...liveNotificationSubscriptions]) {
        const source = sub.source === 'live_session' ? `live notification ${shortId(sub.id)}` : `scheduled update ${shortId(sub.id)}`;
        const observedAt = sub.updatedAt || sub.createdAt;
        add('APNS environment', sub.useSandbox ? 'sandbox' : 'prod', source, observedAt);
        add('Notification types', sub.notificationTypes, source, observedAt);
        add('Mute notifications on arrival', Boolean(sub.muteOnArrival), source, observedAt);
        add('Scheduled days', sub.daysOfWeek, source, observedAt);
        add('Muted legs today', sub.mutedByLegDay, source, observedAt);
        add('Muted leg timestamps', sub.mutedAtByLegDay, source, observedAt);
    }

    for (const session of liveActivitySessions) {
        const source = `live activity ${shortId(session.activityId)}`;
        const observedAt = session.tokenUpdatedAt || session.createdAt;
        add('APNS environment', session.useSandbox ? 'sandbox' : 'prod', source, observedAt);
        add('Preferred service ID', session.preferredServiceId, source, observedAt);
        add('Mute notifications on arrival', Boolean(session.muteOnArrival), source, observedAt);
        add('Mute delay minutes', session.muteDelayMinutes, source, observedAt);
        add('Auto-end on arrival', Boolean(session.autoEndOnArrival), source, observedAt);
        add('Auto-end on departure', Boolean(session.autoEndOnDeparture), source, observedAt);
        add('Journey updates enabled', Boolean(session.journeyUpdatesEnabled), source, observedAt);
        add('Live Activity window start', session.windowStart, source, observedAt);
        add('Live Activity window end', session.windowEnd, source, observedAt);
        add('App active', Boolean(session.appIsActive), source, observedAt);
    }

    if (devicePreferences?.preferences && typeof devicePreferences.preferences === 'object') {
        for (const [key, value] of Object.entries(devicePreferences.preferences)) {
            add(key, value, 'device preference snapshot', devicePreferences.updated_at);
        }
    }

    return Array.from(preferences.values()).sort((left, right) => left.name.localeCompare(right.name));
}

function latestIso(...values) {
    let best = null;
    let bestTime = 0;
    for (const value of values) {
        const time = Date.parse(value || '');
        if (Number.isFinite(time) && time >= bestTime) {
            best = new Date(time).toISOString();
            bestTime = time;
        }
    }
    return best;
}

function deviceListHref({ query, page, pageSize }) {
    const params = new URLSearchParams();
    if (query) params.set('q', query);
    params.set('page', String(page));
    params.set('per_page', String(pageSize));
    return `?${params.toString()}`;
}

function liveActivityAdminHref({ query, page, pageSize }) {
    const params = new URLSearchParams();
    if (query) params.set('q', query);
    params.set('page', String(page));
    params.set('per_page', String(pageSize));
    return `?${params.toString()}`;
}

function formatStation(leg, key) {
    if (!leg || typeof leg !== 'object') return '';
    if (key === 'from') return leg.fromName || leg.from || '';
    return leg.toName || leg.to || '';
}

function formatList(value) {
    return Array.isArray(value) ? value.join(', ') : String(value ?? '');
}

function formatPreferenceValue(value) {
    if (Array.isArray(value)) return value.join(', ');
    if (value && typeof value === 'object') return JSON.stringify(value);
    return String(value);
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

function formatPushToStartTtl(token) {
    if (!token) return '<span class="badge badge-err">missing</span>';
    const ttl = Number(token.ttlSeconds);
    if (ttl === -1) return '<span class="badge badge-warn">no expiry</span>';
    if (ttl === -2) return '<span class="badge badge-err">missing</span>';
    if (!Number.isFinite(ttl)) return '<span class="badge badge-warn">unknown</span>';
    const minimum = Number(token.minimumTtlSeconds || pushToStartTokenTtlPolicy.minimumTtlSeconds || 0);
    const badge = ttl >= minimum ? 'badge-ok' : 'badge-warn';
    const expiry = token.expiresAt ? ` · expires ${formatDate(token.expiresAt)}` : '';
    return `<span class="badge ${badge}">${escapeHtml(formatDurationSeconds(ttl))}</span>${expiry}`;
}

function formatDurationSeconds(seconds) {
    const value = Number(seconds);
    if (!Number.isFinite(value)) return '';
    const days = Math.floor(value / 86400);
    const hours = Math.floor((value % 86400) / 3600);
    const minutes = Math.floor((value % 3600) / 60);
    if (days >= 1) return `${days} day${days === 1 ? '' : 's'}${hours ? ` ${hours} hr` : ''}`;
    if (hours >= 1) return `${hours} hr${hours === 1 ? '' : 's'}${minutes ? ` ${minutes} min` : ''}`;
    if (minutes >= 1) return `${minutes} min`;
    return `${Math.max(0, Math.round(value))} s`;
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

function normalizeDeviceId(value) {
    return typeof value === 'string' ? value.trim() : '';
}

function buildRecentLiveActivityDevices(payloads = [], pushToStartTokens = []) {
    const devices = new Map();
    const ensureDevice = (deviceId) => {
        const normalized = normalizeDeviceId(deviceId);
        if (!normalized) return null;
        if (!devices.has(normalized)) {
            devices.set(normalized, {
                deviceId: normalized,
                lastSeenAt: null,
                sources: new Set(),
                payloadCount: 0,
                lastEvent: null,
                pushToStartTokenUpdatedAt: null,
                pushToStartUseSandbox: null
            });
        }
        return devices.get(normalized);
    };

    for (const payload of Array.isArray(payloads) ? payloads : []) {
        const device = ensureDevice(
            payload?.context?.device_id
            || payload?.context?.target_device_id
            || payload?.device_id
        );
        if (!device) continue;
        device.sources.add('payload');
        device.payloadCount += 1;
        const recordedAt = payload?.recorded_at || payload?.sent_at || null;
        if (isAfter(recordedAt, device.lastSeenAt)) {
            device.lastSeenAt = recordedAt;
            device.lastEvent = payload?.event || payload?.payload?.aps?.event || null;
        }
    }

    for (const token of Array.isArray(pushToStartTokens) ? pushToStartTokens : []) {
        const device = ensureDevice(token?.deviceId);
        if (!device) continue;
        device.sources.add('push-to-start');
        device.pushToStartTokenUpdatedAt = token?.updatedAt || null;
        device.pushToStartUseSandbox = Boolean(token?.useSandbox);
        if (isAfter(token?.updatedAt, device.lastSeenAt)) {
            device.lastSeenAt = token.updatedAt;
            device.lastEvent = device.lastEvent || 'push_to_start_token';
        }
    }

    return Array.from(devices.values()).sort((left, right) => {
        const leftTime = Date.parse(left.lastSeenAt || '') || 0;
        const rightTime = Date.parse(right.lastSeenAt || '') || 0;
        return rightTime - leftTime;
    });
}

function paginateItems(items, page, pageSize) {
    const list = Array.isArray(items) ? items : [];
    const safePageSize = Math.max(1, Math.floor(Number(pageSize) || 20));
    const totalPages = Math.max(1, Math.ceil(list.length / safePageSize));
    const safePage = Math.min(totalPages, Math.max(1, Math.floor(Number(page) || 1)));
    const start = (safePage - 1) * safePageSize;
    return {
        items: list.slice(start, start + safePageSize),
        page: safePage,
        pageSize: safePageSize,
        totalItems: list.length,
        totalPages
    };
}

function isAfter(candidate, current) {
    const candidateTime = Date.parse(candidate || '') || 0;
    const currentTime = Date.parse(current || '') || 0;
    return candidateTime > currentTime;
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
