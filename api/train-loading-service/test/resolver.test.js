import assert from "node:assert/strict";
import test from "node:test";
import { LoadingResolver } from "../lib/resolver.js";

test("resolves RID through Staff data before registering an interest", async () => {
  const calls = [];
  const service = {
    rid: "202608148087187",
    std: "2026-08-14T22:12:00",
    operatorCode: "SE",
    destination: [{ crs: "VIC" }],
    subsequentLocations: [{ crs: "VIC" }],
    formation: { coaches: [{ number: "A1" }] },
  };
  const store = {
    findMapping: async () => null,
    saveMapping: async (request, matched) => ({ rid: matched.rid, serviceID: request.serviceID }),
    registerInterest: async (interest) => calls.push(interest),
    getLoadingDetails: async (rid) => ({ status: "formation_only", rid, coaches: [{ number: "A1" }] }),
  };
  const resolver = new LoadingResolver({
    store,
    staffClient: { getBoard: async () => ({ trainServices: [service] }) },
    staleSeconds: 600,
  });
  const result = await resolver.resolve({
    serviceID: "opaque",
    from: "KTH",
    to: "VIC",
    scheduledDeparture: "22:12",
  });
  assert.equal(result.rid, service.rid);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].service, service);
});

test("does not register an interest for an unresolved request", async () => {
  let registered = false;
  const resolver = new LoadingResolver({
    store: {
      findMapping: async () => null,
      registerInterest: async () => { registered = true; },
    },
    staffClient: { getBoard: async () => ({ trainServices: [] }) },
    staleSeconds: 600,
  });
  const result = await resolver.resolve({ serviceID: "opaque", from: "KTH", to: "VIC", scheduledDeparture: "22:12" });
  assert.equal(result.status, "unresolved");
  assert.equal(registered, false);
});
