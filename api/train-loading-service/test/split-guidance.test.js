import assert from "node:assert/strict";
import test from "node:test";
import { resolveSplitGuidance } from "../lib/split-guidance.js";

const mainService = {
  length: 12,
  subsequentLocations: [
    { crs: "HHE", locationName: "Haywards Heath", length: 12 },
    {
      crs: "WRH",
      locationName: "Worthing",
      length: 4,
      detachFront: false,
      associations: [{ category: "divide", rid: "littlehampton-rid", isCancelled: false }],
    },
    { crs: "PMH", locationName: "Portsmouth Harbour", length: 4 },
  ],
  destination: [{ crs: "PMH" }],
};

const littlehamptonService = {
  locations: [
    { crs: "WRH", locationName: "Worthing", length: 8 },
    { crs: "WWO", locationName: "West Worthing", length: 8 },
    { crs: "LIT", locationName: "Littlehampton", length: 8 },
  ],
  destination: [{ crs: "LIT" }],
};

const details = async (rid) => {
  assert.equal(rid, "littlehampton-rid");
  return littlehamptonService;
};

test("directs a Littlehampton passenger to the validated rear portion", async () => {
  const guidance = await resolveSplitGuidance({
    service: mainService,
    request: { from: "ECR", to: "LIT", length: 12 },
    getServiceDetails: details,
  });

  assert.deepEqual(guidance, {
    splitAt: { crs: "WRH", locationName: "Worthing" },
    destinationCRS: "LIT",
    position: "rear",
    coachCount: 8,
    confidence: "validated_lengths",
  });
});

test("directs a Portsmouth passenger to the remaining front portion", async () => {
  const guidance = await resolveSplitGuidance({
    service: mainService,
    request: { from: "ECR", to: "PMH", length: 12 },
    getServiceDetails: details,
  });

  assert.equal(guidance.position, "front");
  assert.equal(guidance.coachCount, 4);
});

test("can guide a passenger boarding at the dividing station", async () => {
  const guidance = await resolveSplitGuidance({
    service: {
      crs: "WRH",
      locationName: "Worthing",
      length: 12,
      detachFront: false,
      associations: [{ category: "divide", rid: "littlehampton-rid" }],
      subsequentLocations: [{ crs: "PMH", length: 4 }],
    },
    request: { from: "WRH", to: "LIT", length: 12 },
    getServiceDetails: details,
  });

  assert.equal(guidance.position, "rear");
  assert.equal(guidance.coachCount, 8);
});

test("does not show guidance when the passenger leaves before the divide", async () => {
  const guidance = await resolveSplitGuidance({
    service: mainService,
    request: { from: "ECR", to: "HHE", length: 12 },
    getServiceDetails: details,
  });
  assert.equal(guidance, null);
});

test("does not guess when portion lengths do not add up", async () => {
  const guidance = await resolveSplitGuidance({
    service: mainService,
    request: { from: "ECR", to: "LIT", length: 11 },
    getServiceDetails: details,
  });
  assert.equal(guidance, null);
});

test("ignores a cancelled divide association", async () => {
  const cancelled = structuredClone(mainService);
  cancelled.subsequentLocations[1].associations[0].isCancelled = true;
  const guidance = await resolveSplitGuidance({
    service: cancelled,
    request: { from: "ECR", to: "LIT", length: 12 },
    getServiceDetails: details,
  });
  assert.equal(guidance, null);
});
