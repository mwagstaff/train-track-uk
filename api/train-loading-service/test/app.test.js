import assert from "node:assert/strict";
import test from "node:test";
import { createApp } from "../lib/app.js";

const metrics = {
  middleware: (_req, _res, next) => next(),
  registry: { contentType: "text/plain", metrics: async () => "" },
};

test("batch endpoint preserves serviceID keys and isolates per-item errors", async (t) => {
  const app = createApp({
    resolver: {
      resolve: async (request) => request.serviceID === "bad"
        ? Promise.reject(new Error("upstream failed"))
        : { status: "waiting_for_update", rid: "rid-1" },
    },
    health: { status: () => ({ ready: true, feed: { healthy: true } }) },
    metrics,
    maxBatchSize: 50,
  });
  const server = app.listen(0);
  t.after(() => server.close());
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const response = await fetch(`http://127.0.0.1:${port}/api/v1/loading_details/batch`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ services: [{ serviceID: "good" }, { serviceID: "bad" }] }),
  });
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.services.good.rid, "rid-1");
  assert.equal(body.services.bad.status, "upstream_error");
});

test("async route failures are returned as internal errors", async (t) => {
  const app = createApp({
    resolver: {
      resolveCachedServiceID: async () => { throw new Error("database unavailable"); },
    },
    health: { status: () => ({ ready: true, feed: { healthy: true } }) },
    metrics,
    maxBatchSize: 50,
  });
  const server = app.listen(0);
  t.after(() => server.close());
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();
  const response = await fetch(`http://127.0.0.1:${port}/api/v1/loading_details/service-id`);
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: "Internal server error" });
});

test("admin page and active services endpoint are available without authentication", async (t) => {
  const services = [{
    serviceID: "service-1",
    startStation: "LBG",
    endStation: "ORP",
    scheduledDeparture: "00:59",
    rid: "rid-1",
    status: "available",
    loading: [{ number: "A1", percentage: 42, band: "amber" }],
    lastUpdate: "2026-08-15T00:58:00.000Z",
  }];
  const app = createApp({
    resolver: { listActiveServices: async () => services },
    health: { status: () => ({ ready: true, feed: { healthy: true } }) },
    metrics,
    maxBatchSize: 50,
  });
  const server = app.listen(0);
  t.after(() => server.close());
  await new Promise((resolve) => server.once("listening", resolve));
  const { port } = server.address();

  const apiResponse = await fetch(`http://127.0.0.1:${port}/api/v1/admin/services`);
  assert.equal(apiResponse.status, 200);
  assert.equal(apiResponse.headers.get("cache-control"), "no-store");
  assert.deepEqual(await apiResponse.json(), { services });

  const pageResponse = await fetch(`http://127.0.0.1:${port}/admin`);
  const page = await pageResponse.text();
  assert.equal(pageResponse.status, 200);
  assert.match(pageResponse.headers.get("content-type"), /^text\/html/);
  assert.match(page, /Live carriage loading/);
  assert.match(page, /id="services"/);
});
