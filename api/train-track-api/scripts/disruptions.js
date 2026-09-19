#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { disruptionConfig } from '../lib/disruptions/model.js';
import { createPlannedEngineeringProvider } from '../lib/disruptions/notices.js';
import { normalizeFutureStations, futureDisruptions } from '../lib/disruptions/future.js';

// Read-only verification. No database registration, timetable search, or push.
export async function validateDisruptions({ env = process.env, stations, fetchImpl = globalThis.fetch, now = Date.now } = {}) {
    const route = stations === undefined ? null : normalizeFutureStations(stations);
    const config = disruptionConfig(env);
    const stationDefinitions = JSON.parse(await readFile(new URL('../resources/stations.json', import.meta.url), 'utf8'));
    let httpStatus = null;
    const provider = createPlannedEngineeringProvider({ endpoint: config.noticeEndpoint,
        headers: config.noticeHeaders, authorization: config.noticeAuthorization,
        username: config.noticeUsername, password: config.noticePassword, stationDefinitions, now,
        fetchImpl: async (...args) => {
            const response = await fetchImpl(...args);
            httpStatus = response.status;
            return response;
        } });
    const snapshot = await provider.getSnapshot();
    const current = snapshot.notices.filter(notice => !notice.endAt || Date.parse(notice.endAt) > now());
    const unique = notices => new Set(notices.map(notice => notice.incidentId ?? notice.id)).size;
    const response = route ? futureDisruptions(snapshot, route, now()) : null;
    return {
        monitoringMode: config.mode,
        feed: {
            status: !snapshot.available ? 'unavailable' : snapshot.complete === false ? 'partial' : 'available',
            httpStatus, checkedAt: snapshot.checkedAt, reason: snapshot.reason,
            validPlannedIncidents: unique(snapshot.notices), validPeriods: snapshot.notices.length,
            unexpiredPlannedIncidents: unique(current),
            incidentsWithStationMatches: unique(current.filter(notice => notice.stationCRS.length > 0)),
            quarantinedIncidents: snapshot.unverifiedIncidentIds?.length ?? 0
        },
        ...(response ? { route: { stations: route, status: response.status,
            matchingIncidents: response.notices.length, reason: response.reason,
            firstNotices: response.notices.slice(0, 5).map(({ title, startAt, endAt }) => ({ title, startAt, endAt })) } } : {})
    };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    try {
        const { values, positionals } = parseArgs({ allowPositionals: true, options: { stations: { type: 'string' } } });
        if (positionals.length !== 1 || positionals[0] !== 'validate') {
            console.error('Usage: npm run disruptions -- validate [--stations CLK,LBG]');
            process.exitCode = 1;
        } else {
            const report = await validateDisruptions({ stations: values.stations });
            console.log(JSON.stringify(report, null, 2));
            process.exitCode = report.feed.status === 'unavailable' ? 1 : report.feed.status === 'partial' ? 2 : 0;
        }
    } catch {
        // Upstream errors can contain credentials; never echo them to terminals.
        console.error('Disruption validation failed. Check the command, route codes, and configured feed access.');
        process.exitCode = 1;
    }
}
