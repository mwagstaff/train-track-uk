import assert from 'node:assert/strict';
import { once } from 'node:events';
import test from 'node:test';
import express from 'express';
import { MongoClient } from 'mongodb';
import { registerAdminRoutes } from '../lib/admin-portal.js';
import { COLLECTIONS } from '../lib/mongo-client.js';
import { liveActivityManager } from '../lib/live-activity-manager.js';
import { pushToStartTokenStore } from '../lib/push-to-start-token-store.js';
import { testServiceHarness } from '../lib/test-service-harness.js';

test('admin navigation and actions retain the public mount prefix at every page depth', async t => {
    // The Mongo driver never opens a socket; all admin rows are synthetic.
    t.mock.method(MongoClient.prototype, 'connect', async function () { return this; });
    t.mock.method(MongoClient.prototype, 'db', () => fakeDatabase());
    t.mock.method(liveActivityManager, 'listSubscriptions', () => []);
    t.mock.method(pushToStartTokenStore, 'list', async () => []);
    testServiceHarness.start();
    t.after(() => testServiceHarness.reset());

    const app = express();
    const routes = express.Router();
    routes.use(express.urlencoded({ extended: false }));
    registerAdminRoutes(routes);
    // The request reaching a route has /admin/... as its path for both mounts.
    app.use('/train-track', routes);
    app.use(routes);
    const server = app.listen(0, '127.0.0.1');
    await once(server, 'listening');
    t.after(() => new Promise(resolve => {
        server.close(resolve);
        server.closeAllConnections();
    }));
    const origin = `http://127.0.0.1:${server.address().port}`;

    for (const prefix of ['', '/train-track']) {
        for (const trailingSlash of ['', '/']) {
            await t.test(`${prefix || 'direct'} with ${trailingSlash ? 'a trailing slash' : 'no trailing slash'}`, async () => {
                const get = async (path, query = '') => {
                    const url = `${origin}${prefix}${path}${trailingSlash}${query}`;
                    const response = await fetch(url);
                    assert.equal(response.status, 200, url);
                    const html = await response.text();
                    assertAllDestinations(html, url, prefix);
                    return { url, html };
                };

                const dashboard = await get('/admin');
                assertLinks(dashboard, prefix, ['/admin/devices', '/admin/live-activities', '/admin/live-activity-payloads', '/admin/test-harness', '/admin/journey-planner', '/admin/subscriptions/subscription-1', '/admin/notifications/notification-1']);
                const deletionRequest = dashboard.html.match(/fetch\((['"])(.*?)\1/);
                assert.ok(deletionRequest, 'the subscription deletion fetch is present');
                assert.equal(new URL(decodeHtml(deletionRequest[2]), dashboard.url).pathname, `${prefix}/api/v2/notifications/debug/subscriptions`);

                const devices = await get('/admin/devices', '?per_page=1&page=2');
                assertLinks(devices, prefix, ['/admin']);
                assertPager(devices, 'Previous', '/admin/devices', prefix, 'page', '1');
                assertPager(devices, 'Next', '/admin/devices', prefix, 'page', '3');

                const device = await get('/admin/devices/device-1');
                assertLinks(device, prefix, ['/admin/devices', '/admin/subscriptions/subscription-1', '/admin/notifications/notification-1']);
                assertLinks(await get('/admin/subscriptions/subscription-1'), prefix, ['/admin']);
                assertLinks(await get('/admin/notifications/notification-1'), prefix, ['/admin']);

                const activities = await get('/admin/live-activities');
                assertLinks(activities, prefix, ['/admin', '/admin/live-activity-payloads', '/admin/devices/device-1', '/admin/subscriptions/subscription-1', '/admin/live-activity-payloads/payload-1']);
                const activityPage = await get('/admin/live-activities', '?per_page=1&page=2');
                assertPager(activityPage, 'Previous', '/admin/live-activities', prefix, 'page', '1');
                assertPager(activityPage, 'Next', '/admin/live-activities', prefix, 'page', '3');

                const payloads = await get('/admin/live-activity-payloads', '?target_device_id=device-1&device_per_page=1&device_page=2');
                assertLinks(payloads, prefix, ['/admin', '/admin/live-activity-payloads/payload-1']);
                assertPager(payloads, 'Previous devices', '/admin/live-activity-payloads', prefix, 'device_page', '1');
                assertPager(payloads, 'Next devices', '/admin/live-activity-payloads', prefix, 'device_page', '3');
                assertForm(payloads, 'POST', `${prefix}/admin/live-activity-payloads/payload-1/replay`);

                const payload = await get('/admin/live-activity-payloads/payload-1', '?target_device_id=device-1');
                assertLinks(payload, prefix, ['/admin/live-activity-payloads']);
                assertForm(payload, 'POST', `${prefix}/admin/live-activity-payloads/payload-1/replay`);

                // Missing aps.event fails before an APNs client or token lookup is used.
                const replayUrl = `${origin}${prefix}/admin/live-activity-payloads/payload-1/replay${trailingSlash}`;
                const replayResponse = await fetch(replayUrl, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: 'target_device_id=device-1'
                });
                assert.equal(replayResponse.status, 400);
                const replay = { html: await replayResponse.text(), url: replayUrl };
                assert.match(replay.html, /Stored payload is missing aps.event/);
                assertAllDestinations(replay.html, replay.url, prefix);
                assertLinks(replay, prefix, ['/admin/live-activity-payloads']);
                assertForm(replay, 'POST', `${prefix}/admin/live-activity-payloads/payload-1/replay`);
                assert.doesNotMatch(replay.html, /onsubmit=|onclick=/, 'nested replay links work without JavaScript rewrites');

                testServiceHarness.start();
                const harness = await get('/admin/test-harness');
                assertLinks(harness, prefix, ['/admin']);
                for (const action of ['start', 'stop', 'reset']) {
                    assertForm(harness, 'POST', `${prefix}/admin/test-harness/${action}`);
                }
                const forms = extractElements(harness.html, 'form').filter(element => element.method?.toUpperCase() === 'POST');
                assert.ok(forms.some(form => new URL(form.action, harness.url).pathname.match(/\/departures\/[^/]+$/)), 'per-departure update form');
                assert.ok(forms.some(form => new URL(form.action, harness.url).pathname.endsWith('/clear')), 'per-departure clear form');

                for (const [action, message] of [['start', 'started'], ['stop', 'stopped'], ['reset', 'reset'], ['departures/test-service', 'updated'], ['departures/test-service/clear', 'cleared']]) {
                    const url = `${origin}${prefix}/admin/test-harness/${action}${trailingSlash}`;
                    const response = await fetch(url, { method: 'POST', redirect: 'manual' });
                    assert.equal(response.status, 302, url);
                    const redirect = new URL(response.headers.get('location'), url);
                    assert.equal(redirect.pathname, `${prefix}/admin/test-harness`, `redirect from ${url}`);
                    assert.equal(redirect.searchParams.get('message'), message);
                }
            });
        }
    }
});

function assertAllDestinations(html, pageUrl, prefix) {
    const allowed = /^\/admin(?:\/(?:devices(?:\/device-\d+)?|subscriptions\/subscription-\d+|notifications\/notification-\d+|live-activities|live-activity-payloads(?:\/payload-\d+(?:\/replay)?)?|test-harness(?:\/(?:start|stop|reset|departures\/[^/]+(?:\/clear)?))?|journey-planner))?\/?$/;
    for (const element of [...extractElements(html, 'a'), ...extractElements(html, 'form')]) {
        const attribute = element.href ?? element.action ?? '';
        const target = new URL(attribute, pageUrl);
        assert.equal(target.origin, new URL(pageUrl).origin);
        assert.ok(target.pathname.startsWith(`${prefix}/admin`), `${attribute} escaped ${prefix || 'direct'} mount on ${pageUrl}`);
        assert.match(target.pathname.slice(prefix.length), allowed, `${attribute} resolves to an unknown admin path on ${pageUrl}`);
        if (element.method?.toUpperCase() === 'GET') {
            assert.equal(target.pathname.replace(/\/$/, ''), new URL(pageUrl).pathname.replace(/\/$/, ''), 'filter submits on the current admin page');
        }
    }
}

function assertLinks(page, prefix, paths) {
    const destinations = extractElements(page.html, 'a').map(element => new URL(element.href, page.url).pathname);
    for (const path of paths) assert.ok(destinations.includes(`${prefix}${path}`), `${page.url} lacks a working link to ${prefix}${path}`);
}

function assertForm(page, method, path) {
    const forms = extractElements(page.html, 'form');
    assert.ok(forms.some(form => form.method?.toUpperCase() === method && new URL(form.action, page.url).pathname === path), `${page.url} lacks ${method} form to ${path}`);
}

function assertPager(page, text, path, prefix, parameter, expected) {
    const link = [...page.html.matchAll(/<a\b([^>]*)>([^<]*)<\/a>/g)].find(match => match[2] === text);
    assert.ok(link, `${text} link on ${page.url}`);
    const href = link[1].match(/href="([^"]*)"/)[1];
    const target = new URL(decodeHtml(href), page.url);
    assert.equal(target.pathname.replace(/\/$/, ''), `${prefix}${path}`);
    assert.equal(target.searchParams.get(parameter), expected);
}

function extractElements(html, tag) {
    return [...html.matchAll(new RegExp(`<${tag}\\b([^>]*)>`, 'g'))].map(match => Object.fromEntries(
        [...match[1].matchAll(/([a-z-]+)="([^"]*)"/g)].map(attribute => [attribute[1], decodeHtml(attribute[2])])
    ));
}

function decodeHtml(value) {
    return value.replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>');
}

function fakeDatabase() {
    const now = new Date().toISOString();
    const records = {
        [COLLECTIONS.notificationSubscriptions]: Array.from({ length: 3 }, (_, index) => ({
            _id: `subscription-${index + 1}`, id: `subscription-${index + 1}`, deviceId: `device-${index + 1}`,
            createdAt: now, updatedAt: now, source: 'scheduled', daysOfWeek: [1],
            legs: [{ from: 'KTH', to: 'VIC', windowStart: '08:00', windowEnd: '09:00' }]
        })),
        [COLLECTIONS.notificationEvents]: [{ _id: 'notification-1', id: 'notification-1', device_id: 'device-1', sent_at: now, success: true }],
        [COLLECTIONS.liveActivityPayloads]: Array.from({ length: 3 }, (_, index) => ({
            _id: `payload-${index + 1}`, id: `payload-${index + 1}`, recorded_at: now,
            context: { device_id: `device-${index + 1}` }, payload: {}
        }))
    };
    return { collection: name => ({
        find() {
            let rows = records[name] || [];
            return { sort() { return this; }, limit(value) { rows = rows.slice(0, value); return this; }, async toArray() { return structuredClone(rows); } };
        },
        async findOne(query) { return structuredClone((records[name] || []).find(record => record._id === query._id) || null); }
    }) };
}
