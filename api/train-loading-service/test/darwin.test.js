import assert from "node:assert/strict";
import { gzipSync } from "node:zlib";
import test from "node:test";
import { decodeDarwinBody, parseDarwinMessage } from "../lib/darwin.js";
import { encodeFrame, StompFrameParser } from "../lib/stomp.js";

const xml = `<?xml version="1.0"?>
<Pport xmlns:fml="http://www.thalesgroup.com/rtti/PushPort/Formations/v1"
       xmlns:fml2="http://www.thalesgroup.com/rtti/PushPort/Formations/v2"
       ts="2026-08-14T19:00:00+01:00">
  <uR>
    <schedule rid="202608147401272" uid="J01272" trainId="2Z18" ssd="2026-08-14" toc="SE" />
    <scheduleFormations rid="202608147401272">
      <fml2:formation fid="202608147401272-001">
        <fml2:coaches>
          <fml2:coach coachNumber="A1" coachClass="Standard" />
          <fml2:coach coachNumber="A2" coachClass="First" />
        </fml2:coaches>
      </fml2:formation>
    </scheduleFormations>
    <formationLoading rid="202608147401272" fid="202608147401272-001" tpl="VICTRIE" ptd="19:02">
      <fml:loading coachNumber="A1">33</fml:loading>
      <fml:loading coachNumber="A2">67</fml:loading>
    </formationLoading>
  </uR>
</Pport>`;

test("decodes gzip and extracts schedule, formation, and loading", () => {
  const events = parseDarwinMessage(decodeDarwinBody(gzipSync(xml)), { SequenceNumber: "42" });
  assert.deepEqual(events.map((event) => event.type), ["schedule", "formation", "loading"]);
  assert.equal(events[1].coaches[1].number, "A2");
  assert.equal(events[2].coaches[1].percentage, 67);
  assert.equal(events[2].sequence, "42");
});

test("STOMP parser preserves a binary body containing null bytes", () => {
  const body = Buffer.from([0x1f, 0x8b, 0, 1, 2, 0, 3]);
  const frames = [];
  const parser = new StompFrameParser((frame) => frames.push(frame));
  parser.push(encodeFrame("MESSAGE", { MessageType: "LO" }, body));
  assert.equal(frames.length, 1);
  assert.deepEqual(frames[0].body, body);
});
