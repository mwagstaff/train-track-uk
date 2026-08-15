import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig } from "../lib/config.js";
import {
  compareScheduledDepartures,
  loadingBand,
  mappingKey,
  MongoLoadingStore,
  normalizeClockTime,
  selectLoadingForTime,
} from "../lib/store.js";

test("defaults retention to 24 hours", () => {
  assert.equal(loadConfig({}).ttlSeconds, 86_400);
});

test("uses the requested loading thresholds", () => {
  assert.equal(loadingBand(0), "green");
  assert.equal(loadingBand(33), "green");
  assert.equal(loadingBand(34), "amber");
  assert.equal(loadingBand(66), "amber");
  assert.equal(loadingBand(67), "red");
  assert.equal(loadingBand(100), "red");
  assert.equal(loadingBand(null), null);
});

test("selects the loading record for the user's departure location time", () => {
  const loadings = [
    { tiploc: "AAA", publicDeparture: "21:50", observedAt: new Date("2026-08-14T20:00:00Z") },
    { tiploc: "BBB", publicDeparture: "22:12", observedAt: new Date("2026-08-14T20:01:00Z") },
  ];
  assert.equal(selectLoadingForTime(loadings, "2026-08-14T22:12:00+01:00").tiploc, "BBB");
  assert.equal(selectLoadingForTime(loadings, "2026-08-14T21:12:00Z").tiploc, "BBB");
  assert.equal(normalizeClockTime("22:12:30"), "22:12");
});

test("mapping keys include journey context", () => {
  assert.equal(mappingKey({ serviceID: "id", from: "kth", to: "vic", scheduledDeparture: "22:12" }), "id|KTH|VIC|22:12");
});

test("admin services sort by scheduled departure time", () => {
  const services = [
    { serviceID: "late", rid: "3", scheduledDeparture: "22:12" },
    { serviceID: "unknown", rid: "4", scheduledDeparture: null },
    { serviceID: "early-b", rid: "2", scheduledDeparture: "07:05" },
    { serviceID: "early-a", rid: "1", scheduledDeparture: "07:05" },
  ];
  services.sort(compareScheduledDepartures);
  assert.deepEqual(services.map((service) => service.serviceID), ["early-a", "early-b", "late", "unknown"]);
});

test("admin services are limited to active in-memory interests", async () => {
  const now = new Date("2026-08-15T00:30:00.000Z");
  const store = new MongoLoadingStore({
    uri: "mongodb://localhost/train_loading",
    ttlSeconds: 86_400,
    now: () => now,
  });
  store.activeInterests.set("active-rid", new Date("2026-08-16T00:30:00.000Z"));
  store.collection = (name) => {
    if (name === "loading_interests") {
      return {
        find: () => ({
          toArray: async () => [{
            _id: "active-rid",
            serviceID: "service-1",
            context: { from: "LBG", to: "ORP", scheduledDeparture: "00:59" },
          }],
        }),
      };
    }
    if (name === "loading_service_mappings") {
      return { findOne: async () => null };
    }
    throw new Error(`Unexpected collection: ${name}`);
  };
  store.getLoadingDetails = async () => ({
    status: "available",
    location: { tiploc: "LNDNBDE" },
    observedAt: "2026-08-15T00:29:00.000Z",
    coaches: [{ number: "A1", percentage: 42, band: "amber" }],
  });

  assert.deepEqual(await store.listActiveServices({ staleSeconds: 300 }), [{
    serviceID: "service-1",
    startStation: "LBG",
    endStation: "ORP",
    scheduledDeparture: "00:59",
    rid: "active-rid",
    status: "available",
    location: { tiploc: "LNDNBDE" },
    loading: [{ number: "A1", percentage: 42, band: "amber" }],
    lastUpdate: "2026-08-15T00:29:00.000Z",
  }]);
});
