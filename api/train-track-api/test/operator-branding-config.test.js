import assert from 'node:assert/strict';
import test from 'node:test';
import { loadOperatorBrandingConfig } from '../lib/operator-branding-config.js';

const nationalRailOperators = [
    'Avanti West Coast',
    'c2c',
    'Caledonian Sleeper',
    'Chiltern Railways',
    'CrossCountry',
    'East Midlands Railway',
    'Elizabeth line',
    'Gatwick Express',
    'Grand Central',
    'Great Northern',
    'GWR',
    'Greater Anglia',
    'Heathrow Express',
    'Hull Trains',
    'LNER',
    'London Northwestern Railway',
    'London Overground',
    'Lumo',
    'Merseyrail',
    'Northern',
    'ScotRail',
    'South Western Railway',
    'Southeastern',
    'Southern',
    'Stansted Express',
    'Thameslink',
    'TransPennine Express',
    'Transport for Wales',
    'West Midlands Railway'
];

test('operator branding config covers every current National Rail train company', () => {
    const config = loadOperatorBrandingConfig();
    const names = config.operators.map((operator) => operator.name).sort();

    assert.deepEqual(names, [...nationalRailOperators].sort());
    assert.match(config.version, /^\d{4}-\d{2}-\d{2}$/);
    for (const operator of config.operators) {
        assert.match(operator.color_hex, /^#[0-9A-F]{6}$/);
    }
});

test('Lumo branding covers its East Coast and West Coast operator codes', () => {
    const lumo = loadOperatorBrandingConfig().operators.find((operator) => operator.name === 'Lumo');
    assert.deepEqual(lumo.operator_codes, ['LD', 'LF']);
});
