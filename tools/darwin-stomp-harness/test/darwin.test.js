import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import test from "node:test";
import {
  decodeDarwinBody,
  eventMatches,
  FormationTracker,
  parseDarwinMessage,
} from "../lib/darwin.js";

const xml = `<?xml version="1.0" encoding="UTF-8"?>
<Pport xmlns:fml="http://www.thalesgroup.com/rtti/PushPort/Formations/v1"
       xmlns:fml2="http://www.thalesgroup.com/rtti/PushPort/Formations/v2"
       xmlns:sc="http://www.thalesgroup.com/rtti/PushPort/Schedules/v3"
       xmlns="http://www.thalesgroup.com/rtti/PushPort/v16"
       ts="2026-08-14T19:00:00+01:00" version="16.0">
  <uR>
    <schedule rid="202608147401272" uid="J01272" trainId="2Z18" ssd="2026-08-14" toc="SE">
      <sc:OR tpl="VICTRIE" ptd="18:53" wtd="18:53" />
    </schedule>
    <scheduleFormations rid="202608147401272">
      <fml2:formation fid="202608147401272-001">
        <fml2:coaches>
          <fml2:coach coachNumber="A" coachClass="Standard">
            <fml2:toilet status="InService">Accessible</fml2:toilet>
          </fml2:coach>
          <fml2:coach coachNumber="B" coachClass="Standard" />
        </fml2:coaches>
      </fml2:formation>
    </scheduleFormations>
    <formationLoading rid="202608147401272" fid="202608147401272-001" tpl="VICTRIE" ptd="18:53">
      <fml:loading coachNumber="A" src="CIS" srcInst="SE">42</fml:loading>
      <fml:loading coachNumber="B" src="CIS" srcInst="SE">73</fml:loading>
    </formationLoading>
  </uR>
</Pport>`;

test("decodes gzip and extracts schedule, formation, and loading events", () => {
  const decoded = decodeDarwinBody(gzipSync(xml));
  const events = parseDarwinMessage(decoded, { SequenceNumber: "123" });

  assert.equal(events.length, 3);
  assert.deepEqual(events[0], {
    type: "schedule",
    timestamp: "2026-08-14T19:00:00+01:00",
    sequence: "123",
    rid: "202608147401272",
    toc: "SE",
    uid: "J01272",
    trainId: "2Z18",
    serviceStartDate: "2026-08-14",
  });
  assert.equal(events[1].coaches[0].toilet.type, "Accessible");
  assert.equal(events[2].coaches[1].percentage, 73);
});

test("correlates loading with schedule and formation by RID and formation ID", () => {
  const tracker = new FormationTracker();
  const [schedule, formation, loading] = parseDarwinMessage(xml).map((event) => tracker.enrich(event));

  assert.equal(schedule.toc, "SE");
  assert.equal(formation.toc, "SE");
  assert.equal(loading.toc, "SE");
  assert.equal(loading.uid, "J01272");
  assert.equal(loading.coaches[0].coachClass, "Standard");
  assert.equal(loading.coaches[0].toilet.type, "Accessible");
  assert.equal(loading.coaches[0].percentage, 42);
});

test("filters reliably by exact RID and best-effort by learned TOC", () => {
  const tracker = new FormationTracker();
  const events = parseDarwinMessage(xml).map((event) => tracker.enrich(event));

  assert.ok(events.every((event) => eventMatches(event, { toc: "SE" })));
  assert.ok(events.every((event) => eventMatches(event, { rids: new Set(["202608147401272"]) })));
  assert.ok(events.every((event) => !eventMatches(event, { rids: new Set(["other"]) })));
});

test("treats an empty loading element as a clear", () => {
  const clearXml = `<Pport ts="2026-08-14T19:01:00+01:00"><uR><formationLoading rid="r1" fid="f1" tpl="STKP" /></uR></Pport>`;
  const [event] = parseDarwinMessage(clearXml);

  assert.equal(event.type, "loading");
  assert.equal(event.cleared, true);
  assert.deepEqual(event.coaches, []);
});
