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

test("replays recent Darwin events immediately after registering an interest", async () => {
  const calls = [];
  const event = { type: "loading", rid: "rid-1", formationId: "fid-1", coaches: [] };
  const recentEvents = {
    eventsForRid: (rid) => rid === "rid-1" ? [event] : [],
    deleteRid: (rid) => calls.push(["delete", rid]),
  };
  const resolver = new LoadingResolver({
    store: {
      registerInterest: async (interest) => calls.push(["register", interest.rid]),
      applyEvent: async (value) => {
        calls.push(["apply", value]);
        return true;
      },
      getLoadingDetails: async (rid) => ({ status: "available", rid, coaches: [] }),
    },
    staffClient: {},
    staleSeconds: 600,
    recentEvents,
    onReplay: (type, stored) => calls.push(["metric", type, stored]),
  });

  const result = await resolver.resolveRid("rid-1", "2026-08-15T10:30:00+01:00");
  assert.equal(result.status, "available");
  assert.deepEqual(calls, [
    ["register", "rid-1"],
    ["apply", event],
    ["metric", "loading", true],
    ["delete", "rid-1"],
  ]);
});
