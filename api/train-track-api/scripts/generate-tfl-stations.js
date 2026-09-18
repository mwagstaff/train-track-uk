#!/usr/bin/env node
import { readFile, writeFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const baseURL = 'https://api.skynolimit.dev/tube-track/api/v1';
const supportedModes = new Set(['tube', 'elizabeth-line', 'overground', 'dlr']);

// These existing CRS stations are outside Greater London even though TfL serves
// them. Keep this reviewed list explicit; a rectangular coordinate test is not
// an administrative boundary and must not decide which matches are routable.
const outsideLondon = new Set(['AMR', 'BNM', 'BRE', 'BSH', 'CFO', 'CHN', 'CLW', 'CPK',
    'IVR', 'LNY', 'MAI', 'RDG', 'RIC', 'SLO', 'SNF', 'TAP', 'TEO', 'TWY', 'WFH', 'WFJ']);
const reviewed = {
    BET: { id: '910GBTHNLGR', note: 'National Rail Bethnal Green is the Weaver station, not the separate Central line station.' },
    CTK: { id: 'HUBBFR', note: 'Reviewed adjacent interchange via Blackfriars, using the National Rail ALF CTK–BFR WALK allowance of 5 minutes.',
        accessWalkingMinutes: 5, accessNote: 'Walk between City Thameslink and Blackfriars Underground; 5 minutes of walking is included in the station transfer allowance.',
        source: 'National Rail RJTTF939ALF.txt: M=WALK,O=CTK,D=BFR,T=5 (weekday and Sunday records)',
        sourceURL: 'https://assets.nationalrail.co.uk/e8xgegruud3g/6AftQ0QpolLvWpTHEv46wF/d645c9b37c0338c0633b70e46ebf4c89/City_Thameslink__CTK__North.pdf' },
    FST: { id: '940GZZLUTWH', note: 'Reviewed adjacent interchange: c2c identifies Tower Hill as approximately 3 minutes on foot from Fenchurch Street.',
        accessWalkingMinutes: 3, accessNote: 'Walk between Fenchurch Street and Tower Hill Underground; 3 minutes of walking is included in the station transfer allowance.',
        sourceURL: 'https://www.c2c-online.co.uk/stations/london-fenchurch-street-station/' },
    HAF: { id: 'HUBHX4', note: 'Heathrow Terminal 4 Rail shares the Terminal 4 transport interchange.' },
    HWV: { id: 'HUBHX5', note: 'Heathrow Terminal 5 Rail shares the Terminal 5 transport interchange.' },
    HXX: { id: 'HUBH13', note: 'The legacy National Rail Terminals 1-2-3 name identifies the current Terminals 2 & 3 interchange.' },
    KGX: { id: 'HUBKGX', note: 'King’s Cross mainline station accesses the shared King’s Cross St Pancras Underground station.' },
    NWX: { id: 'HUBNWX', note: 'New Cross ELL is the Windrush service at New Cross National Rail station.' },
    SQE: { id: '910GSURREYQ', note: 'Exact station identity reviewed: National Rail catalogue longitude has the wrong sign; do not use it for proximity matching.' },
    STP: { id: 'HUBKGX', note: 'St Pancras accesses the shared King’s Cross St Pancras Underground station. National Rail walks to King’s Cross remain walks.' },
    WAE: { id: '940GZZLUSWK', note: 'Southeastern confirms a direct Waterloo East entrance from Southwark Underground; retain the station interchange allowance.',
        accessNote: 'Use the direct interchange between Waterloo East and Southwark Underground; this route involves steps or an escalator.',
        sourceURL: 'https://www.southeasternrailway.co.uk/travel-information/station-information/stations/london-waterloo-east' }
};
const separateStations = {
    WHP: 'West Hampstead Thameslink is separate from the Underground/Overground entrances; preserve National Rail walking links.'
};

function normalized(name) {
    return name.toLowerCase().replace(/\(london\)/g, '').replace(/^london /, '')
        .replace(/\s+(?:(?:underground|dlr|rail|overground)\s+)?station$/, '').replace(/[^a-z0-9]/g, '');
}
function distanceMetres(a, b) {
    const lat = (Number(a.latitude) + b.latitude) * Math.PI / 360;
    return Math.round(Math.hypot((Number(a.latitude) - b.latitude) * 111_195,
        (Number(a.longitude) - b.longitude) * 111_195 * Math.cos(lat)));
}
function option(name) {
    const index = process.argv.indexOf(name);
    return index < 0 ? undefined : process.argv[index + 1];
}
async function source(endpoint, localFile) {
    if (localFile) return JSON.parse(await readFile(localFile, 'utf8'));
    const response = await fetch(`${baseURL}/${endpoint}`, { signal: AbortSignal.timeout(15_000) });
    if (!response.ok) throw new Error(`${endpoint}: HTTP ${response.status}`);
    return response.json();
}

const nationalRail = JSON.parse(await readFile(path.join(root, 'resources/stations.json'), 'utf8'));
const [catalogue, palette] = await Promise.all([
    source('stations', option('--stations-file')), source('line-colours', option('--colours-file'))
]);
if (!Array.isArray(catalogue.data) || !Array.isArray(palette.data)) throw new Error('Invalid TubeTrack catalogue');
const supportedLines = new Set(palette.data.filter(line => supportedModes.has(line.mode)).map(line => line.id));
const candidates = catalogue.data.filter(station => station.lineIds.some(id => supportedLines.has(id)));
const stations = {};
const unmapped = [];
for (const station of nationalRail.toSorted((a, b) => a.crs.localeCompare(b.crs))) {
    const override = reviewed[station.crs];
    const names = candidates.filter(candidate => [candidate.name, ...candidate.aliases]
        .some(name => normalized(name) === normalized(station.name)));
    const close = names.filter(candidate => distanceMetres(station, candidate) <= 600);
    const match = override ? candidates.find(candidate => candidate.id === override.id) : close.length === 1 ? close[0] : null;
    if (override && !match) throw new Error(`Reviewed mapping missing from API: ${station.crs}/${override.id}`);
    if (match && !outsideLondon.has(station.crs) && !separateStations[station.crs]) {
        stations[station.crs] = {
            name: station.name, tflName: match.name, hubId: match.id.startsWith('HUB') ? match.id : null,
            stopIds: [...match.stopIds].sort(), routingId: match.id.startsWith('HUB') && match.stopIds.length > 1
                ? match.id : match.stopIds[0],
            lineIds: match.lineIds.filter(id => supportedLines.has(id)).sort(),
            match: override ? 'reviewed' : 'exactNameAndLocation', distanceMetres: distanceMetres(station, match),
            ...(override ? Object.fromEntries(Object.entries(override).filter(([key]) => key !== 'id')) : {})
        };
    } else {
        // The box is only an audit window, never a matching/routing rule.
        const inAuditWindow = Number(station.latitude) >= 51.28 && Number(station.latitude) <= 51.70
            && Number(station.longitude) >= -0.52 && Number(station.longitude) <= 0.34;
        if (inAuditWindow || outsideLondon.has(station.crs) || names.length) unmapped.push({
            crs: station.crs, name: station.name,
            reason: outsideLondon.has(station.crs) ? 'outsideLondon'
                : separateStations[station.crs] ?? (close.length > 1 ? 'ambiguousNameMatch'
                    : names.length ? 'nameMatchLocationMismatch' : 'noSupportedCoLocatedStop'),
            ...(names.length ? { candidateIds: names.map(candidate => candidate.id).sort() } : {})
        });
    }
}

// Audit the actual fixed links where the planner can request TfL directions.
let alfEndpoints = [];
const timetableDir = path.join(root, 'resources/timetable_full');
try {
    const files = (await readdir(timetableDir)).filter(name => /ALF\.txt$/i.test(name)).sort();
    const alfFile = option('--alf-file') ?? (files.length ? path.join(timetableDir, files.at(-1)) : null);
    if (alfFile) {
        const alf = await readFile(alfFile, 'utf8');
        const codes = [...new Set(alf.split(/\r?\n/).filter(line => line.startsWith('M=TUBE,'))
            .flatMap(line => [...line.matchAll(/[OD]=([A-Z]{3})(?:,|$)/g)].map(match => match[1])))].sort();
        alfEndpoints = codes.map(crs => ({ crs, mapped: Boolean(stations[crs]),
            ...(!stations[crs] ? { reason: unmapped.find(item => item.crs === crs)?.reason
                ?? (nationalRail.some(item => item.crs === crs) ? 'noReviewedMapping' : 'notInExistingStationCatalogue') } : {}) }));
    }
} catch (error) {
    if (error.code !== 'ENOENT') throw error;
}
const config = { version: 1, source: `${baseURL}/stations`,
    scope: 'Existing National Rail London stations with a supported TfL counterpart; no nearest-station guesses.',
    routingPolicy: 'Use a multi-stop hub to preserve all supported modes; a single-stop hub uses its stopId.',
    auditWindow: { purpose: 'Coverage review only; includes some stations outside London.',
        latitude: [51.28, 51.70], longitude: [-0.52, 0.34] },
    stations, unmapped, alfEndpoints };
const directory = option('--output-dir') ?? path.join(root, 'resources');
await writeFile(path.join(directory, 'london-tfl-stations.json'), `${JSON.stringify(config, null, 2)}\n`);
await writeFile(path.join(directory, 'tfl-line-colours.json'), `${JSON.stringify({ version: 1,
    source: `${baseURL}/line-colours`, lines: palette.data.filter(line => supportedModes.has(line.mode)) }, null, 2)}\n`);
console.log(`Mapped ${Object.keys(stations).length} stations; ${unmapped.length} audit dispositions; ${alfEndpoints.filter(item => !item.mapped).length} ALF endpoints need National Rail fallback.`);
