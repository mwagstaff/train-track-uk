import { MongoClient } from "mongodb";
import { serviceHasActiveDivide } from "./split-guidance.js";
import { ukCalendarDate, ukClockTime } from "./time.js";

const COLLECTIONS = Object.freeze({
  interests: "loading_interests",
  mappings: "loading_service_mappings",
  services: "loading_services",
  formations: "loading_formations",
  loadings: "loading_updates",
});

function databaseNameFromUri(uri) {
  try {
    const pathname = new URL(uri).pathname.replace(/^\/+/, "");
    return pathname ? decodeURIComponent(pathname) : undefined;
  } catch {
    return undefined;
  }
}

const defined = (entries) => Object.fromEntries(entries.filter(([, value]) => value !== undefined));

export function loadingBand(percentage) {
  if (!Number.isFinite(percentage)) return null;
  if (percentage <= 33) return "green";
  if (percentage <= 66) return "amber";
  return "red";
}

export function normalizeClockTime(value) {
  return ukClockTime(value);
}

export function selectLoadingForTime(loadings, scheduledDeparture) {
  if (!Array.isArray(loadings) || loadings.length === 0) return null;
  const requested = normalizeClockTime(scheduledDeparture);
  if (requested) {
    const exact = loadings.filter((loading) => [
      loading.publicDeparture,
      loading.publicArrival,
      loading.workingDeparture,
      loading.workingArrival,
    ].some((value) => normalizeClockTime(value) === requested));
    if (exact.length > 0) {
      return exact.sort((left, right) => new Date(right.observedAt) - new Date(left.observedAt))[0];
    }
  }
  return [...loadings].sort((left, right) => new Date(right.observedAt) - new Date(left.observedAt))[0];
}

export function mappingKey(request) {
  return [
    request.serviceID,
    request.from?.toUpperCase(),
    request.to?.toUpperCase(),
    normalizeClockTime(request.scheduledDeparture),
  ].join("|");
}

export function compareScheduledDepartures(left, right) {
  const sortValue = (service) => {
    const clockTime = normalizeClockTime(service.scheduledDeparture);
    if (!clockTime) return Number.NEGATIVE_INFINITY;
    const [hours, mins] = clockTime.split(":").map(Number);
    const date = service.scheduledDepartureDate ?? ukCalendarDate(service.scheduledDeparture);
    if (!date) return hours * 60 + mins;
    return Date.parse(`${date}T00:00:00Z`) / 60_000 + hours * 60 + mins;
  };
  const timeDifference = sortValue(right) - sortValue(left);
  if (timeDifference !== 0) return timeDifference;
  return (left.serviceID ?? left.rid).localeCompare(right.serviceID ?? right.rid);
}

export function activeUntilForDeparture(scheduledDeparture, now, interestSeconds) {
  const parsed = new Date(scheduledDeparture);
  const base = scheduledDeparture && !Number.isNaN(parsed.getTime()) ? parsed : now;
  return new Date(base.getTime() + interestSeconds * 1_000);
}

function calendarDayDifference(from, to) {
  if (!from || !to) return null;
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

export class MongoLoadingStore {
  constructor({ uri, databaseName, ttlSeconds, interestSeconds = 2 * 60 * 60, now = () => new Date() }) {
    this.uri = uri;
    this.databaseName = databaseName ?? databaseNameFromUri(uri) ?? "train_loading";
    this.ttlSeconds = ttlSeconds;
    this.interestSeconds = interestSeconds;
    this.now = now;
    this.client = null;
    this.db = null;
    this.activeInterests = new Map();
  }

  async init() {
    this.client = new MongoClient(this.uri, {
      maxPoolSize: 10,
      serverSelectionTimeoutMS: 10_000,
    });
    await this.client.connect();
    this.db = this.client.db(this.databaseName);
    await this.createIndexes();
    await this.reloadInterests();
  }

  async createIndexes() {
    await Promise.all(Object.values(COLLECTIONS).map((name) => this.db.collection(name).createIndex(
      { expiresAt: 1 },
      { name: "expires_at_ttl", expireAfterSeconds: 0 },
    )));
    await Promise.all([
      this.collection(COLLECTIONS.mappings).createIndex({ serviceID: 1, updatedAt: -1 }, { name: "service_id" }),
      this.collection(COLLECTIONS.formations).createIndex({ rid: 1, updatedAt: -1 }, { name: "rid_updated" }),
      this.collection(COLLECTIONS.loadings).createIndex({ rid: 1, observedAt: -1 }, { name: "rid_observed" }),
    ]);
  }

  collection(name) {
    if (!this.db) throw new Error("Mongo loading store is not initialized");
    return this.db.collection(name);
  }

  expiresAt() {
    return new Date(this.now().getTime() + this.ttlSeconds * 1_000);
  }

  async reloadInterests() {
    const now = this.now();
    const interests = await this.collection(COLLECTIONS.interests)
      .find({ expiresAt: { $gt: now } }, { projection: { _id: 1, activeUntil: 1, context: 1 } })
      .toArray();
    this.activeInterests.clear();
    for (const interest of interests) {
      const activeUntil = interest.activeUntil
        ?? activeUntilForDeparture(interest.context?.scheduledDeparture, now, this.interestSeconds);
      if (activeUntil > now) this.activeInterests.set(interest._id, activeUntil);
    }
  }

  pruneInterests() {
    const now = this.now().getTime();
    for (const [rid, expiry] of this.activeInterests) {
      if (new Date(expiry).getTime() <= now) this.activeInterests.delete(rid);
    }
  }

  hasInterest(rid) {
    const expiry = this.activeInterests.get(rid);
    if (!expiry) return false;
    if (new Date(expiry).getTime() <= this.now().getTime()) {
      this.activeInterests.delete(rid);
      return false;
    }
    return true;
  }

  activeInterestCount() {
    this.pruneInterests();
    return this.activeInterests.size;
  }

  interestedRids() {
    this.pruneInterests();
    return [...this.activeInterests.keys()];
  }

  async registerInterest({ rid, serviceID, context, service }) {
    const now = this.now();
    const expiresAt = this.expiresAt();
    const activeUntil = activeUntilForDeparture(context?.scheduledDeparture, now, this.interestSeconds);
    if (activeUntil > now) this.activeInterests.set(rid, activeUntil);
    else this.activeInterests.delete(rid);
    await this.collection(COLLECTIONS.interests).updateOne(
      { _id: rid },
      { $set: defined(Object.entries({ serviceID, context, activeUntil, updatedAt: now, expiresAt })) },
      { upsert: true },
    );

    await Promise.all([
      this.collection(COLLECTIONS.services).updateMany({ rid }, { $set: { expiresAt } }),
      this.collection(COLLECTIONS.formations).updateMany({ rid }, { $set: { expiresAt } }),
      this.collection(COLLECTIONS.loadings).updateMany({ rid }, { $set: { expiresAt } }),
    ]);

    if (service) {
      await this.seedFromStaffService(rid, service, expiresAt);
    }
    return activeUntil;
  }

  async seedFromStaffService(rid, service, expiresAt = this.expiresAt()) {
    const now = this.now();
    await this.collection(COLLECTIONS.services).updateOne(
      { _id: rid },
      { $set: {
        rid,
        toc: service.operatorCode,
        operator: service.operator,
        uid: service.uid,
        trainId: service.trainid,
        serviceStartDate: service.sdd,
        updatedAt: now,
        expiresAt,
      } },
      { upsert: true },
    );

    const coaches = (service.formation?.coaches ?? []).map((coach, index) => ({
      number: coach.number ?? coach.coachNumber,
      position: index + 1,
      coachClass: coach.coachClass,
      toilet: coach.toilet ? {
        type: coach.toilet.Value ?? coach.toilet.type,
        status: coach.toilet.status,
      } : undefined,
    })).filter((coach) => coach.number);

    if (coaches.length > 0) {
      await this.collection(COLLECTIONS.formations).updateOne(
        { _id: `${rid}:staff` },
        { $set: {
          rid,
          formationId: "staff",
          source: "staff-ldb",
          coaches,
          updatedAt: now,
          expiresAt,
        } },
        { upsert: true },
      );
    }
  }

  async saveMapping(request, service) {
    const now = this.now();
    const expiresAt = this.expiresAt();
    const document = {
      _id: mappingKey(request),
      serviceID: request.serviceID,
      rid: service.rid,
      context: {
        from: request.from.toUpperCase(),
        to: request.to.toUpperCase(),
        scheduledDeparture: request.scheduledDeparture,
      },
      operator: service.operator,
      toc: service.operatorCode,
      hasDivideAssociation: serviceHasActiveDivide(service, request.from),
      updatedAt: now,
      expiresAt,
    };
    await this.collection(COLLECTIONS.mappings).updateOne(
      { _id: document._id },
      { $set: document },
      { upsert: true },
    );
    return document;
  }

  async findMapping(request) {
    return this.collection(COLLECTIONS.mappings).findOne({
      _id: mappingKey(request),
      expiresAt: { $gt: this.now() },
    });
  }

  async findLatestMapping(serviceID) {
    return this.collection(COLLECTIONS.mappings).findOne(
      { serviceID, expiresAt: { $gt: this.now() } },
      { sort: { updatedAt: -1 } },
    );
  }

  async applyEvent(event) {
    if (!this.hasInterest(event.rid)) return false;
    const expiresAt = this.expiresAt();
    const now = this.now();

    if (event.type === "deactivated") {
      await Promise.all([
        this.collection(COLLECTIONS.formations).deleteMany({ rid: event.rid }),
        this.collection(COLLECTIONS.loadings).deleteMany({ rid: event.rid }),
      ]);
      return true;
    }

    if (event.type === "schedule") {
      await this.collection(COLLECTIONS.services).updateOne(
        { _id: event.rid },
        { $set: defined(Object.entries({
          rid: event.rid,
          toc: event.toc,
          uid: event.uid,
          trainId: event.trainId,
          serviceStartDate: event.serviceStartDate,
          observedAt: event.timestamp ? new Date(event.timestamp) : now,
          updatedAt: now,
          expiresAt,
        })) },
        { upsert: true },
      );
      return true;
    }

    if (event.type === "formation") {
      const id = `${event.rid}:${event.formationId}`;
      if (event.cleared) {
        await Promise.all([
          this.collection(COLLECTIONS.formations).deleteOne({ _id: id }),
          this.collection(COLLECTIONS.loadings).deleteMany({ rid: event.rid, formationId: event.formationId }),
        ]);
      } else {
        await this.collection(COLLECTIONS.formations).updateOne(
          { _id: id },
          { $set: {
            rid: event.rid,
            formationId: event.formationId,
            source: event.source,
            sourceInstance: event.sourceInstance,
            coaches: event.coaches.map((coach, index) => ({ ...coach, position: index + 1 })),
            observedAt: event.timestamp ? new Date(event.timestamp) : now,
            updatedAt: now,
            expiresAt,
          } },
          { upsert: true },
        );
      }
      return true;
    }

    if (event.type === "loading") {
      const id = `${event.rid}:${event.formationId}:${event.tiploc ?? "unknown"}`;
      if (event.cleared) {
        await this.collection(COLLECTIONS.loadings).deleteOne({ _id: id });
      } else {
        await this.collection(COLLECTIONS.loadings).updateOne(
          { _id: id },
          { $set: {
            rid: event.rid,
            formationId: event.formationId,
            tiploc: event.tiploc,
            publicArrival: event.publicArrival,
            publicDeparture: event.publicDeparture,
            workingArrival: event.workingArrival,
            workingDeparture: event.workingDeparture,
            coaches: event.coaches,
            sequence: event.sequence,
            observedAt: event.timestamp ? new Date(event.timestamp) : now,
            updatedAt: now,
            expiresAt,
          } },
          { upsert: true },
        );
      }
      return true;
    }

    return false;
  }

  async getLoadingDetails(rid, { scheduledDeparture, staleSeconds }) {
    const [service, formations, loadings] = await Promise.all([
      this.collection(COLLECTIONS.services).findOne({ rid, expiresAt: { $gt: this.now() } }),
      this.collection(COLLECTIONS.formations).find({ rid, expiresAt: { $gt: this.now() } }).sort({ updatedAt: -1 }).toArray(),
      this.collection(COLLECTIONS.loadings).find({ rid, expiresAt: { $gt: this.now() } }).sort({ observedAt: -1 }).toArray(),
    ]);
    const loading = selectLoadingForTime(loadings, scheduledDeparture);
    const formation = formations.find((item) => item.formationId === loading?.formationId) ?? formations[0];
    const loadingByCoach = new Map((loading?.coaches ?? []).map((coach) => [coach.number, coach]));
    const formationCoaches = formation?.coaches ?? [];
    const ordered = formationCoaches.length > 0 ? formationCoaches : (loading?.coaches ?? []);
    const coaches = ordered.map((coach, index) => {
      const live = loadingByCoach.get(coach.number);
      const percentage = Number.isFinite(live?.percentage) ? Math.max(0, Math.min(100, live.percentage)) : null;
      return {
        number: coach.number,
        position: coach.position ?? index + 1,
        percentage,
        band: loadingBand(percentage),
        coachClass: coach.coachClass,
        toilet: coach.toilet,
      };
    });
    for (const live of loading?.coaches ?? []) {
      if (!coaches.some((coach) => coach.number === live.number)) {
        const percentage = Number.isFinite(live.percentage) ? Math.max(0, Math.min(100, live.percentage)) : null;
        coaches.push({
          number: live.number,
          position: coaches.length + 1,
          percentage,
          band: loadingBand(percentage),
        });
      }
    }

    const observedAt = loading?.observedAt ?? formation?.observedAt ?? service?.observedAt ?? null;
    const ageSeconds = observedAt ? Math.max(0, Math.floor((this.now() - new Date(observedAt)) / 1_000)) : null;
    let status = loading ? "available" : formation ? "formation_only" : "waiting_for_update";
    if (loading && Number.isFinite(staleSeconds) && ageSeconds > staleSeconds) status = "stale";

    return {
      status,
      rid,
      formationId: loading?.formationId ?? formation?.formationId ?? null,
      operator: service?.operator ?? null,
      toc: service?.toc ?? null,
      location: loading ? { tiploc: loading.tiploc } : null,
      observedAt: observedAt ? new Date(observedAt).toISOString() : null,
      ageSeconds,
      coaches,
    };
  }

  async listActiveServices({ staleSeconds }) {
    const rids = this.interestedRids();
    if (rids.length === 0) return [];

    const interests = await this.collection(COLLECTIONS.interests)
      .find({ _id: { $in: rids }, expiresAt: { $gt: this.now() } })
      .toArray();
    const services = await Promise.all(interests.map(async (interest) => {
      const mapping = await this.collection(COLLECTIONS.mappings).findOne(
        { rid: interest._id, expiresAt: { $gt: this.now() } },
        { sort: { updatedAt: -1 } },
      );
      const context = interest.context ?? mapping?.context ?? {};
      const loading = await this.getLoadingDetails(interest._id, {
        scheduledDeparture: context.scheduledDeparture,
        staleSeconds,
      });
      const scheduledDepartureDate = ukCalendarDate(context.scheduledDeparture);
      return {
        serviceID: interest.serviceID ?? mapping?.serviceID ?? null,
        startStation: context.from ?? null,
        endStation: context.to ?? null,
        scheduledDeparture: normalizeClockTime(context.scheduledDeparture),
        scheduledDepartureDate,
        departureDayOffset: calendarDayDifference(ukCalendarDate(this.now()), scheduledDepartureDate),
        rid: interest._id,
        status: loading.status,
        location: loading.location,
        loading: loading.coaches,
        lastUpdate: loading.observedAt,
      };
    }));

    return services.sort(compareScheduledDepartures);
  }

  async ping() {
    await this.db.command({ ping: 1 });
    return true;
  }

  async close() {
    await this.client?.close();
  }
}
