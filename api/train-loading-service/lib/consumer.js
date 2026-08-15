import { decodeDarwinBody, messageType, parseDarwinMessage } from "./darwin.js";

export async function processDarwinFrame({ frame, store, recentEvents, metrics }) {
  const type = messageType(frame.headers);
  metrics.onStompMessage(type);
  if (type && !["SC", "SF", "LO"].includes(type)) return;

  const xml = decodeDarwinBody(frame.body);
  if (type === "SC") {
    const interestedRids = store.interestedRids();
    if (interestedRids.length === 0 || !interestedRids.some((rid) => xml.includes(rid))) return;
  }

  for (const event of parseDarwinMessage(xml, frame.headers)) {
    const matched = store.hasInterest(event.rid);
    if (matched) await store.applyEvent(event);
    else if (event.type === "formation" || event.type === "loading") recentEvents.add(event);
    metrics.onEvent(event.type, matched);
  }
  metrics.setRecentCacheEvents(recentEvents.size());
}
