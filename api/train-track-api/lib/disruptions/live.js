import { MonitorError } from './model.js';

export function normalizeLiveOperator(query) {
    if (Object.keys(query).some(key => key !== 'operator')
        || query.operator !== undefined && (typeof query.operator !== 'string' || !/^[A-Z0-9]{2}$/.test(query.operator))) {
        throw new MonitorError('Supply only an optional two-character operator code, such as SE.');
    }
    return query.operator;
}

/** Published nationwide incidents, independent of journey monitoring and the timetable. */
export function createLiveDisruptions({ provider, now = Date.now, refreshMs = 60000, maxStaleMs = 600000 }) {
    return {
        async get(operator) {
            const latest = await provider.getSnapshot({ staleWhileRevalidate: true });
            const snapshot = latest.available ? latest : provider.getLastAvailableSnapshot();
            const at = now(), checked = Date.parse(snapshot?.checkedAt);
            const ageMs = Number.isFinite(checked) ? Math.max(0, at - checked) : null;
            const usable = snapshot?.available && ageMs !== null && ageMs <= maxStaleMs;
            const stale = !latest.available || ageMs === null || ageMs >= refreshMs;
            const metadata = { status: !usable ? 'unavailable' : snapshot.complete === false ? 'partial' : 'available',
                checkedAt: snapshot?.checkedAt ?? null, lastAttemptAt: latest.checkedAt,
                ageSeconds: ageMs === null ? null : Math.floor(ageMs / 1000), stale,
                reason: !latest.available ? latest.reason : !usable ? 'snapshot_expired' : snapshot.reason };
            if (!usable) return { ...metadata, incidents: [] };

            const incidents = new Map();
            for (const notice of snapshot.notices) {
                if (notice.planned || Date.parse(notice.startAt) > at || notice.endAt && Date.parse(notice.endAt) <= at) continue;
                if (operator && !notice.allOperators && !notice.operators.some(item => item.code === operator)) continue;
                if (incidents.has(notice.incidentId)) continue;
                incidents.set(notice.incidentId, { id: notice.incidentId, title: notice.title, body: notice.body,
                    sourceURL: notice.sourceURL, operators: notice.operators, allOperators: notice.allOperators,
                    routesAffected: notice.routesAffected, priority: notice.priority,
                    updatedAt: notice.updatedAt ?? null, startAt: notice.startAt, endAt: notice.endAt });
            }
            return { ...metadata, incidents: [...incidents.values()].sort((a, b) =>
                (a.priority ?? 3) - (b.priority ?? 3) || (b.updatedAt ?? '').localeCompare(a.updatedAt ?? '') || a.id.localeCompare(b.id)) };
        }
    };
}
