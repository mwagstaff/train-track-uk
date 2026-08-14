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

const array = (value) => (value === undefined ? [] : Array.isArray(value) ? value : [value]);

function text(value) {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "object") return value["#text"];
  return String(value);
}

function parseCoach(coach) {
  const toilet = coach.toilet;
  return {
    coachNumber: coach.coachNumber,
    coachClass: coach.coachClass,
    toilet: toilet
      ? {
          type: text(toilet),
          status: typeof toilet === "object" ? toilet.status : undefined,
        }
      : undefined,
  };
}

function parseLoading(loading) {
  const percentage = Number.parseInt(text(loading), 10);
  return {
    coachNumber: loading.coachNumber,
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

export function parseDarwinMessage(xml, headers = {}) {
  const document = parser.parse(xml);
  const root = document.Pport ?? document;
  const updates = [...array(root.uR), ...array(root.sR)];
  const events = [];

  for (const update of updates) {
    for (const schedule of array(update.schedule)) {
      events.push({
        type: "schedule",
        timestamp: root.ts,
        sequence: headers.SequenceNumber ?? headers.sequenceNumber,
        rid: schedule.rid,
        toc: schedule.toc,
        uid: schedule.uid,
        trainId: schedule.trainId,
        serviceStartDate: schedule.ssd,
      });
    }

    for (const group of array(update.scheduleFormations)) {
      for (const formation of array(group.formation)) {
        const coaches = array(formation.coaches?.coach).map(parseCoach);
        events.push({
          type: "formation",
          timestamp: root.ts,
          sequence: headers.SequenceNumber ?? headers.sequenceNumber,
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
        sequence: headers.SequenceNumber ?? headers.sequenceNumber,
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

  return events;
}

export class FormationTracker {
  constructor() {
    this.schedules = new Map();
    this.formations = new Map();
  }

  enrich(event) {
    if (event.type === "schedule") {
      this.schedules.set(event.rid, event);
      return event;
    }

    const schedule = this.schedules.get(event.rid);
    if (event.type === "formation") {
      this.formations.set(`${event.rid}:${event.formationId}`, event);
      return { ...event, toc: schedule?.toc, uid: schedule?.uid, trainId: schedule?.trainId };
    }

    if (event.type === "loading") {
      const formation = this.formations.get(`${event.rid}:${event.formationId}`);
      const coaches = event.coaches.map((loading) => ({
        ...loading,
        ...formation?.coaches.find((coach) => coach.coachNumber === loading.coachNumber),
        percentage: loading.percentage,
        source: loading.source,
        sourceInstance: loading.sourceInstance,
      }));
      return {
        ...event,
        toc: schedule?.toc,
        uid: schedule?.uid,
        trainId: schedule?.trainId,
        coaches,
      };
    }

    return event;
  }
}

export function eventMatches(event, { rids = new Set(), toc = "SE", all = false } = {}) {
  if (all) return true;
  if (rids.size > 0) return rids.has(event.rid);
  return event.toc === toc;
}

export function formatEvent(event) {
  const prefix = `[${event.timestamp ?? new Date().toISOString()}]`;
  const identity = `rid=${event.rid}${event.toc ? ` toc=${event.toc}` : ""}`;

  if (event.type === "schedule") {
    return `${prefix} SCHEDULE ${identity} uid=${event.uid ?? "?"} train=${event.trainId ?? "?"}`;
  }

  if (event.type === "formation") {
    if (event.cleared) return `${prefix} FORMATION ${identity} fid=${event.formationId} cleared`;
    const coaches = event.coaches
      .map((coach) => {
        const toilet = coach.toilet?.type && coach.toilet.type !== "None" ? `, toilet=${coach.toilet.type}/${coach.toilet.status ?? "InService"}` : "";
        return `${coach.coachNumber ?? "?"}(${coach.coachClass ?? "class unknown"}${toilet})`;
      })
      .join(" ");
    return `${prefix} FORMATION ${identity} fid=${event.formationId} coaches=${event.coaches.length} ${coaches}`;
  }

  if (event.type === "loading") {
    if (event.cleared) return `${prefix} LOADING ${identity} fid=${event.formationId} at=${event.tiploc ?? "?"} cleared`;
    const coaches = event.coaches.map((coach) => `${coach.coachNumber ?? "?"}:${coach.percentage ?? "?"}%`).join(" ");
    return `${prefix} LOADING ${identity} fid=${event.formationId} at=${event.tiploc ?? "?"} ${coaches}`;
  }

  return `${prefix} ${event.type.toUpperCase()} ${identity}`;
}
