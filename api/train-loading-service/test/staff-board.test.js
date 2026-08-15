import assert from "node:assert/strict";
import test from "node:test";
import { formatRailDataTimestamp, matchStaffService, StaffDepartureBoardClient } from "../lib/staff-board.js";

const request = {
  serviceID: "opaque-id",
  from: "KTH",
  to: "VIC",
  scheduledDeparture: "2026-08-14T22:12:00+01:00",
  destinationCRS: "VIC",
  length: 8,
};

test("formats Staff API timestamps in Europe/London and buckets to 30 minutes", () => {
  assert.equal(formatRailDataTimestamp(request.scheduledDeparture), "20260814T220000");
});

test("matches an iOS UTC timestamp against Staff UK wall-clock time during BST", () => {
  const board = {
    trainServices: [{
      rid: "rid-bst",
      std: "2026-08-14T22:12:00",
      subsequentLocations: [{ crs: "VIC" }],
      destination: [{ crs: "VIC" }],
    }],
  };
  const result = matchStaffService(board, {
    from: "KTH",
    to: "VIC",
    scheduledDeparture: "2026-08-14T21:12:00Z",
  });
  assert.equal(result.status, "resolved");
  assert.equal(result.service.rid, "rid-bst");
});

test("matches any operator rather than filtering to Southeastern", () => {
  const service = {
    rid: "rid-gtr",
    std: "2026-08-14T22:12:00",
    operatorCode: "GX",
    length: 8,
    destination: [{ crs: "VIC" }],
    subsequentLocations: [{ crs: "VIC" }],
  };
  const result = matchStaffService({ trainServices: [service] }, request);
  assert.equal(result.status, "resolved");
  assert.equal(result.service.rid, "rid-gtr");
});

test("refuses to guess when equally good services are ambiguous", () => {
  const service = {
    std: "2026-08-14T22:12:00",
    destination: [{ crs: "VIC" }],
    subsequentLocations: [{ crs: "VIC" }],
  };
  const result = matchStaffService({
    trainServices: [{ ...service, rid: "one" }, { ...service, rid: "two" }],
  }, { ...request, destinationCRS: undefined, length: undefined });
  assert.equal(result.status, "unresolved");
  assert.equal(result.reason, "ambiguous_staff_service_match");
});

test("deduplicates concurrent Staff API calls for the same station bucket", async () => {
  let calls = 0;
  const client = new StaffDepartureBoardClient({
    apiKey: "test",
    baseUrl: "https://example.test",
    timeoutMs: 1_000,
    cacheTtlMs: 30_000,
    fetchImpl: async () => {
      calls += 1;
      return { ok: true, status: 200, json: async () => ({ trainServices: [] }) };
    },
  });
  await Promise.all([
    client.getBoard("KTH", "2026-08-14T22:12:00+01:00"),
    client.getBoard("KTH", "2026-08-14T22:24:00+01:00"),
  ]);
  assert.equal(calls, 1);
});
