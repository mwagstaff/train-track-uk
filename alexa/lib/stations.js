const fs = require('fs');
const path = require('path');

const stationsPath = path.join(__dirname, '..', 'stations.json');
let stations = [];

try {
  const raw = fs.readFileSync(stationsPath, 'utf8');
  stations = JSON.parse(raw);
} catch (e) {
  console.error('Failed to load stations.json', e);
  stations = [];
}

const normalize = (s) => s
  .toLowerCase()
  .replace(/\s+/g, ' ')
  .replace(/[()]/g, '')
  .replace(/\b(stn|station)\b/g, '')
  .replace(/[^a-z0-9 \-]/g, '')
  .trim();

// Certain single-word names are ambiguous across the UK network.
// Provide explicit defaults for common ambiguous terms.
// Keyed by normalized spoken value; value is the target CRS code.
const AMBIGUOUS_DEFAULTS = {
  // Prefer London Victoria when the user simply says "Victoria"
  victoria: 'VIC'
};

function scoreMatch(normQuery, normName) {
  if (normQuery === normName) return 100;
  if (normName.startsWith(normQuery)) return 90;
  if (normName.includes(normQuery)) return 80;
  // Token overlap score
  const qTokens = new Set(normQuery.split(' '));
  const nTokens = new Set(normName.split(' '));
  let overlap = 0;
  qTokens.forEach((t) => { if (nTokens.has(t)) overlap++; });
  return overlap > 0 ? 60 + overlap : 0;
}

function findStationCRS(query) {
  if (!query) return null;
  const normQuery = normalize(query);

  // If this query has a known ambiguous default, return it immediately
  const defaultCrs = AMBIGUOUS_DEFAULTS[normQuery];
  if (defaultCrs) {
    const match = stations.find((s) => (s.crs || '').toUpperCase() === defaultCrs);
    if (match) return match;
  }

  let best = null;
  let bestScore = 0;
  for (const s of stations) {
    const normName = normalize(s.name);
    const sc = scoreMatch(normQuery, normName);
    if (sc > bestScore) {
      bestScore = sc;
      best = s;
      if (sc >= 100) break; // perfect
    }
  }
  return bestScore >= 60 ? best : null;
}

function sanitizeStationName(s) {
  return s && String(s).trim();
}

module.exports = { findStationCRS, sanitizeStationName, normalize };
