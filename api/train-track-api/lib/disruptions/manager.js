import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { addDays, londonDate } from '../planner/time.js';
import { allowDeviceData } from '../device-data-deletion-state.js';
import { DisruptionStore } from './store.js';
import { BankHolidayCalendar } from './holidays.js';
import { futureDisruptions, normalizeFutureStations } from './future.js';
import { assessTimetableReadiness, decideProfileAdvisories } from './policy.js';
import { matchEngineeringNotices } from './notices.js';
import { ENGINEERING_RELEVANCE_VERSION, noticeAffectsJourney } from './relevance.js';
import { HORIZON_DAYS, MonitorError, deviceIdentifier, disruptionConfig, hash, horizonDates,
    isQuietTime, londonInstant, monitoringWindow, normalizeMonitors, profileJob, timetableSeason, windowChunks } from './model.js';

const unavailableNotices = { available: false, checkedAt: null, notices: [], reason: 'Engineering notices are not connected yet.' };

export class DisruptionMonitor {
    constructor({ planner, store = new DisruptionStore(), notices, holidays = new BankHolidayCalendar(),
        pushClient, isHolidayMode = () => false, config = disruptionConfig(), now = Date.now,
        readIngestion, observe = () => {}, logger = console } = {}) {
        this.planner = planner; this.store = store; this.notices = notices; this.holidays = holidays;
        this.pushClient = pushClient; this.isHolidayMode = isHolidayMode; this.config = config;
        this.now = now; this.observe = observe; this.logger = logger;
        this.readIngestion = readIngestion ?? (async () => {
            try { return JSON.parse(await readFile(join(planner.config.dataDirectory, 'ingestion-state.json'), 'utf8')); }
            catch { return null; }
        });
        this.deleted = new Set(); this.stopped = false; this.running = null; this.timer = null;
        this.noticeSnapshot = unavailableNotices; this.status = null; this.readiness = { ready: false, reason: 'Timetable checks are being prepared.' };
        this.refreshAt = 0; this.demandRefreshAt = 0; this.deviceIterator = null;
        this.synchronizing = new Map();
    }
    assertDevice(deviceId) {
        if (this.deleted.has(deviceId) || !allowDeviceData(deviceId)) throw new MonitorError('Monitoring has stopped for this installation.', 410, 'DEVICE_DELETED');
    }
    async synchronize(body) {
        const input = normalizeMonitors(body);
        this.assertDevice(input.deviceId);
        const previous = this.synchronizing.get(input.deviceId) ?? Promise.resolve();
        const task = previous.catch(() => {}).then(async () => {
            this.assertDevice(input.deviceId);
            const device = await this.store.saveDevice(input, this.now());
            this.assertDevice(input.deviceId);
            // Do not wait for routing or an engineering provider on a user request.
            this.demandRefreshAt = 0;
            return this.presentation(device);
        });
        this.synchronizing.set(input.deviceId, task);
        try { return await task; }
        finally { if (this.synchronizing.get(input.deviceId) === task) this.synchronizing.delete(input.deviceId); }
    }
    async get(deviceId) {
        deviceIdentifier(deviceId); this.assertDevice(deviceId);
        return this.presentation(await this.store.getDevice(deviceId));
    }
    async future(stationsValue) {
        const stations = normalizeFutureStations(stationsValue);
        const snapshot = await this.notices?.getSnapshot().catch(() => unavailableNotices) ?? unavailableNotices;
        return futureDisruptions(snapshot, stations, this.now());
    }
    presentation(device) {
        const state = device?.stateRevision === device?.revision ? device?.state : null;
        const stale = !state?.checkedAt || this.now() - Date.parse(state.checkedAt) > this.config.refreshMs * 3;
        const active = this.config.mode === 'active';
        return { mode: this.config.mode, horizonDays: HORIZON_DAYS,
            monitors: (device?.monitors ?? []).map(monitor => {
                const saved = state?.monitors?.find(row => row.id === monitor.id);
                return { id: monitor.id, status: !monitor.enabled ? 'disabled' : !active ? 'pending'
                    : stale ? 'pending' : saved?.status ?? 'pending', lastCheckedAt: saved?.lastCheckedAt ?? null,
                reason: !monitor.enabled ? null : !active ? 'Advance monitoring is being prepared.'
                    : stale ? 'Waiting for the next background check.' : saved?.reason ?? null };
            }),
            advisories: active ? (state?.advisories ?? []).filter(advisory => Date.parse(advisory.endAt) > this.now()
                && currentRelevance(advisory)) : [] };
    }
    async purgeDevice(deviceId) {
        this.deleted.add(deviceId);
        // Revision checks plus this marker prevent stale in-flight fanout from
        // recreating data after the deletion service removes the documents.
        await Promise.allSettled([this.synchronizing.get(deviceId), this.running]);
        return 1;
    }
    start() {
        if (this.config.mode === 'off' || this.timer || this.running) return;
        this.stopped = false;
        const run = async () => {
            try { await this.tick(); }
            catch { this.observe({ outcome: 'error' }); this.logger.warn('[disruptions] Background check failed; it will retry.'); }
            if (!this.stopped) { this.timer = setTimeout(run, this.config.intervalMs); this.timer.unref?.(); }
        };
        this.timer = setTimeout(run, 1000); this.timer.unref?.();
    }
    stop() { this.stopped = true; clearTimeout(this.timer); this.timer = null; this.controller?.abort(); }
    tick() {
        if (this.running) return this.running;
        if (this.stopped || this.config.mode === 'off') return Promise.resolve();
        this.running = this.runTick().finally(() => { this.running = null; });
        return this.running;
    }
    async refreshSources() {
        if (this.now() < this.refreshAt) return;
        const [status, ingestion, notices] = await Promise.all([
            this.planner.status().catch(() => null), this.readIngestion().catch(() => null),
            this.notices?.getSnapshot().catch(() => unavailableNotices) ?? unavailableNotices,
            this.holidays.refresh()
        ]);
        this.status = status;
        this.readiness = assessTimetableReadiness(status, ingestion, { now: this.now(), maxSourceAgeHours: this.config.maxSourceAgeHours });
        this.noticeSnapshot = notices;
        this.refreshAt = this.now() + this.config.refreshMs;
        this.observe({ ready: this.readiness.ready, noticesAvailable: notices.available });
    }
    async runTick() {
        await this.refreshSources();
        if (!this.deviceIterator && this.now() >= this.demandRefreshAt) this.deviceIterator = this.store.devices()[Symbol.asyncIterator]();
        if (this.deviceIterator) {
            const next = await this.deviceIterator.next();
            if (next.done) {
                this.deviceIterator = null; this.demandRefreshAt = this.now() + this.config.refreshMs;
                if (this.store.stats) this.observe(await this.store.stats(this.now()));
            }
            else if (!this.deleted.has(next.value.deviceId)) await this.reconcileDevice(next.value);
        }
        if (!this.readiness.ready || this.stopped || this.planner.maintenanceAvailable?.() === false) return;
        // Re-read ingestion before every CPU admission. Import work can begin
        // between the less frequent source refreshes.
        const ingestion = await this.readIngestion();
        if (!assessTimetableReadiness(this.status, ingestion, { now: this.now(), maxSourceAgeHours: this.config.maxSourceAgeHours }).ready) {
            this.refreshAt = 0; return;
        }
        const job = await this.store.claim(this.readiness.datasetVersion, this.now());
        if (!job) return;
        this.controller = new AbortController();
        try {
            const result = await this.planner.disruptionProfile({ from: job.stations[0], to: job.stations.at(-1),
                via: job.stations.slice(1, -1), date: job.date, startMinutes: job.startMinutes, endMinutes: job.endMinutes },
            { signal: this.controller.signal });
            if (result.datasetVersion !== job.datasetVersion) {
                await this.store.defer(job, this.now(), 'dataset_changed'); this.refreshAt = 0;
            } else if (!result.complete && ['SEARCH_TIMEOUT', 'DATASET_UNAVAILABLE', 'DATASET_STALE', 'CURSOR_EXPIRED'].includes(result.reason)
                && (job.failures ?? 0) < 3) {
                await this.store.defer(job, this.now(), result.reason);
            } else {
                await this.store.complete(job, result, this.now());
                this.observe({ outcome: result.complete ? 'complete' : 'unknown' });
            }
        } catch (error) {
            const deferred = ['SEARCH_DEFERRED', 'SEARCH_CANCELLED'].includes(error.code);
            if (!deferred && ((job.failures ?? 0) >= 3 || ['INVALID_REQUEST', 'UNKNOWN_STATION', 'UNSUPPORTED_DATE'].includes(error.code))) {
                await this.store.complete(job, { complete: false, datasetVersion: job.datasetVersion, date: job.date,
                    startMinutes: job.startMinutes, endMinutes: job.endMinutes, reason: 'UNAVAILABLE' }, this.now());
            } else await this.store.defer(job, this.now(), deferred ? 'deferred' : 'unavailable');
            this.observe({ outcome: deferred ? 'deferred' : 'error' });
        } finally { this.controller = null; }
    }
    async reconcileDevice(device) {
        if (this.deleted.has(device.deviceId)) return;
        const now = this.now(), dates = [addDays(londonDate(now), -1), ...horizonDates(now)], version = this.readiness.datasetVersion;
        const state = { checkedAt: new Date(now).toISOString(), monitors: [], advisories: [] };
        for (const monitor of device.monitors) {
            if (this.stopped || this.planner.maintenanceAvailable?.() === false) return;
            if (!monitor.enabled) { state.monitors.push({ id: monitor.id, status: 'disabled', lastCheckedAt: null, reason: null }); continue; }
            const dayChunks = dates.map(date => ({ date, chunks: windowChunks(monitor, date).filter(chunk => {
                try { return londonInstant(chunk.date, chunk.endMinutes) > now; } catch { return true; }
            }) }));
            const currentJobs = dayChunks.flatMap(day => day.chunks.map(chunk => profileJob(monitor.stations, chunk, version, now,
                Math.max(0, Math.round((Date.parse(chunk.date) - Date.parse(londonDate(now))) / 86400000)) * 2)));
            const baselineJobs = currentJobs.flatMap(job => [7, 14].map(days => profileJob(monitor.stations,
                { date: addDays(job.date, -days), startMinutes: job.startMinutes, endMinutes: job.endMinutes }, version, now, job.priority + 1)))
                .filter(job => this.holidays.ordinary(job.date));
            const historical = this.readiness.ready && this.store.historicalProfiles
                ? await this.store.historicalProfiles(monitor.stations, baselineJobs, version) : [];
            const baselineByID = new Map(historical.map(row => [profileJob(monitor.stations, row, version, now)._id, row]));
            if (this.readiness.ready) {
                const jobs = [...currentJobs, ...baselineJobs.filter(job => !baselineByID.has(job._id))];
                for (let offset = 0; offset < jobs.length; offset += 500) await this.store.enqueue(jobs.slice(offset, offset + 500), now);
            }
            const records = this.readiness.ready ? await this.store.profiles([...currentJobs, ...baselineJobs].map(job => job._id)) : [];
            const byID = new Map(records.map(row => [row._id, row]));
            const prior = device.stateRevision === device.revision ? device.state?.advisories?.filter(row => row.monitorId === monitor.id) ?? [] : [];
            const verifiedWindows = { replacement_bus: [], comparison: [] }, observed = [];
            let unknown = !this.readiness.ready, pending = false, lastChecked = null;
            for (const day of dayChunks) {
                if (!day.chunks.length) continue;
                const profiles = day.chunks.map(chunk => byID.get(profileJob(monitor.stations, chunk, version, now)._id));
                const allFinished = profiles.every(row => row?.status === 'complete');
                if (!allFinished) pending = true;
                for (let index = 0; index < profiles.length; index++) {
                    const record = profiles[index], chunk = day.chunks[index];
                    if (!record?.profile?.complete) { if (record?.status === 'complete') unknown = true; continue; }
                    const current = record.profile;
                    lastChecked = !lastChecked || record.checkedAt < lastChecked ? record.checkedAt : lastChecked;
                    const baselines = this.holidays.ordinary(chunk.date) ? [7, 14].map(days => {
                        const date = addDays(chunk.date, -days);
                        if (!this.holidays.ordinary(date) || timetableSeason(date) !== timetableSeason(chunk.date)) return null;
                        const key = profileJob(monitor.stations, { ...chunk, date }, version, now)._id;
                        const row = byID.get(key)?.profile?.complete ? byID.get(key) : baselineByID.get(key);
                        if (!row?.profile?.complete || this.matchNotices(monitor, { ...chunk, date }).length) return null;
                        return row.profile;
                    }).filter(Boolean) : [];
                    const decision = decideProfileAdvisories(current, baselines, {});
                    if (!decision.comparisonReady) pending = true;
                    if (decision.state === 'unknown') unknown = true;
                    else {
                        try {
                            const interval = [londonInstant(chunk.date, chunk.startMinutes), londonInstant(chunk.date, chunk.endMinutes)];
                            verifiedWindows.replacement_bus.push(interval);
                            if (decision.comparisonReady) verifiedWindows.comparison.push(interval);
                        } catch { unknown = true; }
                    }
                    for (const advisory of decision.advisories) observed.push({ ...advisory, date: chunk.date,
                        startMinutes: chunk.startMinutes, endMinutes: chunk.endMinutes, notifyReady: allFinished,
                        checkedAt: new Date(record.checkedAt).toISOString() });
                }
            }
            const timetableAdvisories = groupTimetableAdvisories(monitor, observed).map(advisory => {
                // Rolling past an already-warned hour must not create a new
                // incident/push. Preserve the original onset for an ongoing
                // contiguous warning, while future revised periods stay distinct.
                const earlier = prior.find(row => row.confidence === 'timetable' && row.kind === advisory.kind
                    && row.startAt < advisory.startAt && row.endAt >= advisory.startAt
                    && Date.parse(advisory.startAt) <= now);
                return earlier ? { ...advisory, id: earlier.id, startAt: earlier.startAt } : advisory;
            });
            // Keep known warnings while a replacement snapshot is pending, but
            // remove them only after a complete successful recheck of that day.
            const retained = prior.filter(row => row.confidence === 'timetable' && Date.parse(row.endAt) > now
                && !intervalCovered(Math.max(now, Date.parse(row.startAt)), Date.parse(row.endAt),
                    row.kind === 'replacement_bus' ? verifiedWindows.replacement_bus : verifiedWindows.comparison));
            state.advisories.push(...new Map([...timetableAdvisories, ...retained].map(row => [row.id, row])).values());
            if (this.noticeSnapshot.available) {
                const official = this.officialAdvisories(monitor, byID, now);
                const unverified = this.noticeSnapshot.unverifiedIncidentIds;
                const incomplete = this.noticeSnapshot.complete === false;
                const unidentified = incomplete && (!Array.isArray(unverified) || !unverified.length
                    || unverified.some(id => typeof id !== 'string' || !id));
                const retainedIDs = new Set((Array.isArray(unverified) ? unverified : [])
                    .filter(id => typeof id === 'string').map(id => hash([monitor.stations, id])));
                // A malformed upstream incident cannot prove that its earlier
                // warning has ended. Other successfully checked incidents can
                // still be updated or cleared from the same feed snapshot.
                const held = incomplete ? prior.filter(row => row.confidence === 'confirmed' && currentRelevance(row)
                    && Date.parse(row.endAt) > now && (unidentified || retainedIDs.has(row.id))) : [];
                state.advisories.push(...new Map([...held, ...official].map(row => [row.id, row])).values());
            } else state.advisories.push(...prior.filter(row => row.confidence === 'confirmed' && currentRelevance(row) && Date.parse(row.endAt) > now));
            state.monitors.push({ id: monitor.id, status: !currentJobs.length ? 'pending' : unknown ? 'unavailable' : pending ? 'pending' : 'checked',
                lastCheckedAt: lastChecked ? new Date(lastChecked).toISOString() : null,
                reason: !currentJobs.length ? 'No selected travel hours fall in the next seven days. Update your monitoring dates if needed.'
                    : !this.readiness.ready ? readinessMessage(this.readiness.reason) : unknown ? 'Some journey times could not be verified.'
                    : pending ? 'Checking your upcoming journeys when capacity is available.'
                        : this.noticeSnapshot.available && this.noticeSnapshot.complete === false
                            ? 'Timetable checks completed. Some published engineering notices could not be verified; existing warnings are retained.'
                        : this.noticeSnapshot.available ? 'No additional changes found in the supported timetable. Late changes remain possible.'
                            : 'Timetable checks completed. Published engineering notices are currently unavailable; late changes remain possible.' });
        }
        if (this.deleted.has(device.deviceId)) return;
        if (await this.store.saveState(device, state)) await this.deliver(device, state.advisories);
    }
    matchNotices(monitor, chunk) {
        if (!this.noticeSnapshot.available) return [];
        return matchEngineeringNotices(this.noticeSnapshot.notices, { stations: monitor.stations, ...chunk });
    }
    officialAdvisories(monitor, _records, now) {
        const matches = new Map();
        // Published notices can precede the seven-day detailed horizon. Match
        // only actual chosen travel dates/hours, up to the source's 12 weeks.
        const relevant = this.noticeSnapshot.notices.filter(notice => noticeAffectsJourney(notice, monitor.stations));
        if (!relevant.length) return [];
        const incidentVersions = new Map();
        for (const notice of relevant) {
            const id = notice.incidentId ?? notice.id;
            const periods = incidentVersions.get(id) ?? [];
            // Copy-only edits remain visible in-app without repeating a push.
            periods.push([notice.title, notice.startAt, notice.endAt]);
            incidentVersions.set(id, periods);
        }
        for (let offset = -1; offset < 84; offset++) {
            const date = addDays(londonDate(now), offset);
            const selected = monitoringWindow(monitor, date);
            for (const chunk of selected ? [{ date, ...selected }] : []) {
                let start, end;
                try { start = londonInstant(chunk.date, chunk.startMinutes); end = londonInstant(chunk.date, chunk.endMinutes); } catch { continue; }
                if (end <= now) continue;
                for (const notice of matchEngineeringNotices(relevant, { ...chunk, stations: monitor.stations })) {
                    const startAt = new Date(Math.max(start, Date.parse(notice.startAt))).toISOString();
                    const endAt = new Date(Math.min(end, notice.endAt ? Date.parse(notice.endAt) : end)).toISOString();
                    const key = notice.incidentId ?? notice.id;
                    const previous = matches.get(key);
                    if (previous) {
                        previous.startAt = previous.startAt < startAt ? previous.startAt : startAt;
                        previous.endAt = previous.endAt > endAt ? previous.endAt : endAt;
                        previous.affectedWindows.push({ startAt, endAt });
                    }
                    else matches.set(key, { id: hash([monitor.stations, key]), monitorId: monitor.id,
                        kind: notice.kind, title: notice.title, body: `This planned work may affect your journey during your monitored hours. ${notice.body}`, startAt, endAt,
                        sourceURL: notice.sourceURL, confidence: 'confirmed', relevanceVersion: ENGINEERING_RELEVANCE_VERSION,
                        checkedAt: this.noticeSnapshot.checkedAt,
                        extraMinutes: null, affectedWindows: [{ startAt, endAt }],
                        notificationVersion: hash(incidentVersions.get(key).map(period => JSON.stringify(period)).sort()) });
                }
            }
        }
        return [...matches.values()].map(advisory => {
            const windows = [];
            for (const window of advisory.affectedWindows.sort((a, b) => a.startAt.localeCompare(b.startAt))) {
                const last = windows.at(-1);
                if (last && last.endAt >= window.startAt) last.endAt = last.endAt > window.endAt ? last.endAt : window.endAt;
                else windows.push({ ...window });
            }
            return { ...advisory, affectedWindows: windows };
        });
    }
    async deliver(device, advisories) {
        if (this.config.mode !== 'active' || !this.pushClient?.isConfigured() || !device.pushToken
            || this.deleted.has(device.deviceId) || this.isHolidayMode(device.deviceId) || isQuietTime(this.now(), this.config)) return;
        const severity = { closure: 5, replacement_bus: 4, direct_unavailable: 3, engineering: 2, longer_journey: 1 };
        const selected = [];
        for (const advisory of [...advisories].sort((a, b) => (severity[b.kind] ?? 0) - (severity[a.kind] ?? 0))) {
            if (!currentRelevance(advisory) || advisory.notifyReady === false || Date.parse(advisory.endAt) <= this.now()) continue;
            if (selected.some(other => other.monitorId === advisory.monitorId && advisoryWindowsOverlap(other, advisory))) continue;
            selected.push(advisory);
        }
        for (const advisory of selected) {
            if (!device.monitors.find(row => row.id === advisory.monitorId)?.push_enabled || advisory.notifyReady === false
                || Date.parse(advisory.endAt) <= this.now()) continue;
            // A multi-day official incident has one receipt per route/incident;
            // subsequent dates are represented by the earliest remaining day.
            const fingerprint = advisory.notificationVersion ?? hash([advisory.kind, advisory.startAt, advisory.endAt,
                advisory.extraMinutes == null ? null : Math.round(advisory.extraMinutes / 5)]);
            const receipt = await this.store.claimDelivery(device, advisory, fingerprint, this.now());
            if (!receipt) continue;
            let sent = false;
            try {
                const latest = await this.store.getDevice(device.deviceId);
                if (this.deleted.has(device.deviceId) || latest?.revision !== device.revision || this.isHolidayMode(device.deviceId)) continue;
                const monitor = latest.monitors.find(row => row.id === advisory.monitorId);
                if (!monitor?.enabled || !monitor.push_enabled) continue;
                const when = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London', weekday: 'short', day: 'numeric', month: 'short' })
                    .format(new Date(advisory.startAt));
                const response = await this.pushClient.sendNotification(device.pushToken, { aps: { alert: {
                    title: 'Upcoming journey disruption', body: `${monitor.name} · ${when}: ${advisory.title.slice(0, 250)}${advisory.extraMinutes ? ` (+${Math.round(advisory.extraMinutes)} min)` : ''}` }, sound: 'default',
                    'thread-id': `disruptions-${monitor.id}` }, alert_type: 'upcoming_disruption', monitor_id: monitor.id,
                    advisory_id: advisory.id, from: monitor.stations[0], to: monitor.stations.at(-1), travel_date: londonDate(Date.parse(advisory.startAt)) },
                { useSandbox: device.useSandbox, event: 'upcoming_disruption', collapseId: receipt._id,
                    expiration: Math.floor(Date.parse(advisory.endAt) / 1000), context: { device_id: device.deviceId, monitor_id: monitor.id } });
                sent = response?.status === 200;
                if (response?.isBadToken) await this.store.clearPushToken(latest, this.now());
            } finally {
                if (!this.deleted.has(device.deviceId)) await this.store.finishDelivery(receipt, fingerprint, sent, this.now());
            }
        }
    }
}

export function groupTimetableAdvisories(monitor, observations) {
    const groups = [];
    for (const item of [...observations].sort((a, b) => `${a.kind}:${a.date}`.localeCompare(`${b.kind}:${b.date}`) || a.startMinutes - b.startMinutes)) {
        const previous = groups.at(-1);
        if (previous && previous.kind === item.kind && previous.date === item.date && previous.endMinutes === item.startMinutes) {
            previous.endMinutes = item.endMinutes;
            if (Number.isFinite(item.extraMinutes) && (!Number.isFinite(previous.extraMinutes) || item.extraMinutes > previous.extraMinutes)) {
                previous.extraMinutes = item.extraMinutes;
                previous.body = item.body;
            }
        } else groups.push({ ...item });
    }
    return groups.flatMap(group => {
        try {
            return [{ id: hash([monitor.stations, group.kind, group.date, group.startMinutes]), monitorId: monitor.id,
                kind: group.kind, title: group.title, body: group.body,
                startAt: new Date(londonInstant(group.date, group.startMinutes)).toISOString(),
                endAt: new Date(londonInstant(group.date, group.endMinutes)).toISOString(),
                sourceURL: null, confidence: 'timetable', checkedAt: group.checkedAt, extraMinutes: group.extraMinutes ?? null,
                notifyReady: group.notifyReady !== false }];
        } catch { return []; }
    });
}

function readinessMessage(reason) {
    if (reason === 'timetable_update_gap' || reason === 'timetable_stale' || reason === 'ingestion_check_stale') {
        return 'Waiting for up-to-date timetable information. Published engineering notices can still appear.';
    }
    if (reason === 'ingestion_in_progress') return 'Timetable information is being updated. Checks will resume shortly.';
    return 'Journey times cannot currently be verified. Published engineering notices can still appear.';
}

function currentRelevance(advisory) {
    return advisory.confidence !== 'confirmed' || advisory.relevanceVersion === ENGINEERING_RELEVANCE_VERSION;
}

function intervalCovered(start, end, windows) {
    let covered = start;
    for (const [from, to] of [...windows].sort((a, b) => a[0] - b[0])) {
        if (from > covered) break;
        if (to > covered) covered = to;
        if (covered >= end) return true;
    }
    return false;
}

function advisoryWindowsOverlap(left, right) {
    const windows = advisory => advisory.affectedWindows?.length ? advisory.affectedWindows : [advisory];
    return windows(left).some(a => windows(right).some(b => a.startAt < b.endAt && a.endAt > b.startAt));
}
