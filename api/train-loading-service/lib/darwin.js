import { gunzipSync } from "node:zlib";
import { XMLParser } from "fast-xml-parser";

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "",
  removeNSPrefix: true,
  parseAttributeValue: false,
  parseTagValue: false,
  trimValues: true,
});

const array = (value) => value === undefined ? [] : Array.isArray(value) ? value : [value];

function text(value) {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "object") return value["#text"];
  return String(value);
}

function parseCoach(coach) {
  const toilet = coach.toilet;
  return {
    number: coach.coachNumber,
    coachClass: coach.coachClass,
    toilet: toilet ? {
      type: text(toilet),
      status: typeof toilet === "object" ? toilet.status : undefined,
    } : undefined,
  };
}

function parseLoading(loading) {
  const percentage = Number.parseInt(text(loading), 10);
  return {
    number: loading.coachNumber,
    percentage: Number.isNaN(percentage) ? undefined : percentage,
    source: loading.src,
    sourceInstance: loading.srcInst,
  };
}

export function decodeDarwinBody(body) {
  const buffer = Buffer.isBuffer(body) ? body : Buffer.from(body);
  const xml = buffer[0] === 0x1f && buffer[1] === 0x8b ? gunzipSync(buffer) : buffer;
  return xml.toString("utf8");
}

export function messageType(headers = {}) {
  const entry = Object.entries(headers).find(([key]) => key.toLowerCase() === "messagetype");
  return entry?.[1];
}

export function parseDarwinMessage(xml, headers = {}) {
  const document = parser.parse(xml);
  const root = document.Pport ?? document;
  const updates = [...array(root.uR), ...array(root.sR)];
  const events = [];
  const sequence = headers.SequenceNumber ?? headers.sequenceNumber;

  for (const update of updates) {
    for (const schedule of array(update.schedule)) {
      events.push({
        type: "schedule",
        timestamp: root.ts,
        sequence,
        rid: schedule.rid,
        toc: schedule.toc,
        uid: schedule.uid,
        trainId: schedule.trainId,
        serviceStartDate: schedule.ssd,
      });
    }

    for (const deactivated of array(update.deactivatedSchedule)) {
      events.push({
        type: "deactivated",
        timestamp: root.ts,
        sequence,
        rid: deactivated.rid ?? text(deactivated),
      });
    }

    for (const group of array(update.scheduleFormations)) {
      for (const formation of array(group.formation)) {
        const coaches = array(formation.coaches?.coach).map(parseCoach);
        events.push({
          type: "formation",
          timestamp: root.ts,
          sequence,
          rid: group.rid,
          formationId: formation.fid,
          source: formation.src,
          sourceInstance: formation.srcInst,
          coaches,
          cleared: coaches.length === 0,
        });
      }
    }

    for (const loading of array(update.formationLoading)) {
      const coaches = array(loading.loading).map(parseLoading);
      events.push({
        type: "loading",
        timestamp: root.ts,
        sequence,
        rid: loading.rid,
        formationId: loading.fid,
        tiploc: loading.tpl?.trim(),
        publicArrival: loading.pta,
        publicDeparture: loading.ptd,
        workingArrival: loading.wta,
        workingDeparture: loading.wtd,
        coaches,
        cleared: coaches.length === 0,
      });
    }
  }

  return events.filter((event) => event.rid);
}
