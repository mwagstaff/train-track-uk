import client from "prom-client";

export function createMetrics() {
  const registry = new client.Registry();
  client.collectDefaultMetrics({ register: registry, prefix: "train_loading_" });

  const stompConnected = new client.Gauge({
    name: "train_loading_stomp_connected",
    help: "Whether the Darwin STOMP subscription is connected",
    registers: [registry],
  });
  const stompLastMessage = new client.Gauge({
    name: "train_loading_stomp_last_message_timestamp_seconds",
    help: "Unix timestamp of the last Darwin MESSAGE frame",
    registers: [registry],
  });
  const stompMessages = new client.Counter({
    name: "train_loading_stomp_messages_total",
    help: "Darwin MESSAGE frames received by message type",
    labelNames: ["message_type"],
    registers: [registry],
  });
  const sequenceGaps = new client.Counter({
    name: "train_loading_stomp_sequence_gaps_total",
    help: "Detected gaps in the unfiltered Darwin sequence",
    registers: [registry],
  });
  const events = new client.Counter({
    name: "train_loading_events_total",
    help: "Parsed Darwin events by type and storage result",
    labelNames: ["event_type", "result"],
    registers: [registry],
  });
  const interests = new client.Gauge({
    name: "train_loading_active_interests",
    help: "Number of RIDs currently retained as user interests",
    registers: [registry],
  });
  const resolutions = new client.Counter({
    name: "train_loading_resolutions_total",
    help: "Staff departure-board resolution outcomes",
    labelNames: ["result"],
    registers: [registry],
  });
  const staffRequests = new client.Counter({
    name: "train_loading_staff_requests_total",
    help: "Staff departure-board calls by outcome",
    labelNames: ["outcome"],
    registers: [registry],
  });
  const staffDuration = new client.Histogram({
    name: "train_loading_staff_request_duration_seconds",
    help: "Staff departure-board request duration",
    buckets: [0.1, 0.25, 0.5, 1, 2, 4, 8],
    registers: [registry],
  });
  const httpDuration = new client.Histogram({
    name: "train_loading_http_request_duration_seconds",
    help: "Loading API request duration",
    labelNames: ["method", "route", "status"],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10],
    registers: [registry],
  });

  return {
    registry,
    onStompState(status) {
      stompConnected.set(status.state === "subscribed" ? 1 : 0);
      if (status.lastMessageAt) stompLastMessage.set(new Date(status.lastMessageAt).getTime() / 1_000);
    },
    onStompMessage(type) { stompMessages.inc({ message_type: type ?? "unknown" }); },
    onSequenceGap() { sequenceGaps.inc(); },
    onEvent(type, stored) { events.inc({ event_type: type, result: stored ? "stored" : "ignored" }); },
    setInterests(value) { interests.set(value); },
    onResolution(result) { resolutions.inc({ result }); },
    onStaffRequest({ outcome, durationSeconds }) {
      staffRequests.inc({ outcome });
      staffDuration.observe(durationSeconds);
    },
    middleware(req, res, next) {
      const startedAt = process.hrtime.bigint();
      res.on("finish", () => {
        const route = req.route?.path ?? req.path;
        const seconds = Number(process.hrtime.bigint() - startedAt) / 1_000_000_000;
        httpDuration.observe({ method: req.method, route, status: String(res.statusCode) }, seconds);
      });
      next();
    },
  };
}
