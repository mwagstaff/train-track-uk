import { MonitorError, hash } from './model.js';
import { noticeAffectsJourney } from './relevance.js';

export function normalizeFutureStations(value) {
    if (typeof value !== 'string' || value.length > 23 || !/^[A-Z]{3}(?:,[A-Z]{3}){1,5}$/.test(value)) {
        throw new MonitorError('Supply two to six ordered station CRS codes, separated by commas.');
    }
    const stations = value.split(',');
    if (new Set(stations).size !== stations.length) throw new MonitorError('Use distinct stations in travel order.');
    return stations;
}

/** Browsing published work is independent of monitoring preferences, timetable
 * readiness and push rollout. Conservative affected-service matching does not
 * claim to establish the full route taken by an itinerary. */
export function futureDisruptions(snapshot, stations, now = Date.now()) {
    const checked = Date.parse(snapshot?.checkedAt);
    const checkedAt = Number.isFinite(checked) ? new Date(checked).toISOString() : null;
    if (!snapshot?.available) return { stations, status: 'unavailable', checkedAt, notices: [],
        reason: snapshot?.reason === 'not_configured' ? 'Published engineering notices are not connected yet.'
            : 'Published engineering notices are temporarily unavailable. Please try again later.' };

    const incidents = new Map();
    let partial = snapshot.complete === false || !Array.isArray(snapshot.notices);
    for (const notice of Array.isArray(snapshot.notices) ? snapshot.notices : []) {
        if (!noticeAffectsJourney(notice, stations)) continue;
        const key = notice.incidentId || notice.id;
        const start = Date.parse(notice.startAt), end = notice.endAt == null ? null : Date.parse(notice.endAt);
        if (typeof key !== 'string' || !key || !Number.isFinite(start) || end !== null && (!Number.isFinite(end) || end <= start)) {
            partial = true; continue;
        }
        if (end !== null && end <= now) continue;
        const window = { startAt: new Date(start).toISOString(), endAt: end === null ? null : new Date(end).toISOString() };
        let incident = incidents.get(key);
        if (!incident) {
            incident = { id: hash(['future', stations, key]), title: notice.title,
                body: `This published work may affect your journey. ${notice.body}`,
                sourceURL: notice.sourceURL, kind: 'engineering', affectedWindows: [] };
            incidents.set(key, incident);
        }
        incident.affectedWindows.push(window);
    }
    const notices = [...incidents.values()].map(incident => {
        const windows = [];
        for (const window of incident.affectedWindows.sort((a, b) => a.startAt.localeCompare(b.startAt))) {
            const previous = windows.at(-1);
            if (previous && (previous.endAt === null || previous.endAt >= window.startAt)) {
                if (previous.endAt !== null) previous.endAt = window.endAt === null ? null
                    : previous.endAt > window.endAt ? previous.endAt : window.endAt;
            } else windows.push(window);
        }
        return { ...incident, startAt: windows[0].startAt, endAt: windows.at(-1).endAt, affectedWindows: windows };
    }).sort((a, b) => a.startAt.localeCompare(b.startAt) || a.id.localeCompare(b.id));

    return { stations, status: partial ? 'partial' : 'available', checkedAt, notices,
        reason: partial ? 'Some published engineering notices could not be verified. These notices may affect your journey; further works may be missing.'
            : 'These published notices identify your journey’s stations in an affected service or explicitly close one of them. They may affect your journey; works without enough route detail may be missing.' };
}
