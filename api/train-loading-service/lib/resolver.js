import { matchStaffService } from "./staff-board.js";
import { resolveSplitGuidance, serviceHasActiveDivide } from "./split-guidance.js";

export function validateLoadingRequest(request) {
  const required = ["serviceID", "from", "to", "scheduledDeparture"];
  const missing = required.filter((field) => !request?.[field]);
  if (missing.length > 0) return `Missing required fields: ${missing.join(", ")}`;
  if (!/^[A-Z]{3}$/i.test(request.from) || !/^[A-Z]{3}$/i.test(request.to)) return "from and to must be three-letter CRS codes";
  return null;
}

export class LoadingResolver {
  constructor({
    store,
    staffClient,
    staleSeconds,
    recentEvents,
    onResolution = () => {},
    onReplay = () => {},
  }) {
    this.store = store;
    this.staffClient = staffClient;
    this.staleSeconds = staleSeconds;
    this.recentEvents = recentEvents;
    this.onResolution = onResolution;
    this.onReplay = onReplay;
  }

  async registerInterest(interest) {
    await this.store.registerInterest(interest);
    const events = this.recentEvents?.eventsForRid(interest.rid) ?? [];
    for (const event of events) {
      const stored = await this.store.applyEvent(event);
      this.onReplay(event.type, stored);
    }
    if (events.length > 0) this.recentEvents.deleteRid(interest.rid);
  }

  async resolve(request) {
    const validationError = validateLoadingRequest(request);
    if (validationError) {
      this.onResolution("invalid");
      return { status: "invalid", error: validationError };
    }

    let mapping = await this.store.findMapping(request);
    let service;
    if (!mapping) {
      const board = await this.staffClient.getBoard(request.from, request.scheduledDeparture);
      const match = matchStaffService(board, request);
      if (match.status !== "resolved") {
        this.onResolution(match.reason);
        return match;
      }
      service = match.service;
      mapping = await this.store.saveMapping(request, service);
    }

    await this.registerInterest({
      rid: mapping.rid,
      serviceID: request.serviceID,
      context: {
        from: request.from.toUpperCase(),
        to: request.to.toUpperCase(),
        scheduledDeparture: request.scheduledDeparture,
      },
      service,
    });
    this.onResolution("resolved");
    return this.details(mapping.rid, request, mapping, service);
  }

  async resolveCachedServiceID(serviceID) {
    const mapping = await this.store.findLatestMapping(serviceID);
    if (!mapping) {
      return {
        status: "mapping_context_required",
        error: "A cold serviceID lookup also requires from, to, and scheduledDeparture",
      };
    }
    await this.registerInterest({ rid: mapping.rid, serviceID, context: mapping.context });
    return this.details(mapping.rid, mapping.context, mapping);
  }

  async resolveRid(rid, scheduledDeparture) {
    if (!rid) return { status: "invalid", error: "rid is required" };
    await this.registerInterest({ rid, context: { scheduledDeparture } });
    return this.details(rid, { scheduledDeparture });
  }

  async listActiveServices() {
    return this.store.listActiveServices({ staleSeconds: this.staleSeconds });
  }

  async details(rid, request, mapping = {}, service) {
    const [details, splitGuidance] = await Promise.all([
      this.store.getLoadingDetails(rid, {
        scheduledDeparture: request.scheduledDeparture,
        staleSeconds: this.staleSeconds,
      }),
      this.splitGuidance(rid, request, mapping, service),
    ]);
    return {
      serviceID: request.serviceID ?? mapping.serviceID ?? null,
      ...details,
      splitGuidance,
    };
  }

  async splitGuidance(rid, request, mapping, matchedService) {
    if (!request?.from || !request?.to) return null;
    if (matchedService && !serviceHasActiveDivide(matchedService, request.from)) return null;
    if (!matchedService && mapping.hasDivideAssociation === false) return null;

    try {
      const service = matchedService ?? await this.staffClient.getServiceDetailsByRid(rid);
      return await resolveSplitGuidance({
        service,
        request,
        getServiceDetails: (associatedRid) => this.staffClient.getServiceDetailsByRid(associatedRid),
      });
    } catch {
      // Split guidance is optional and must never make live loading unavailable.
      return null;
    }
  }
}
