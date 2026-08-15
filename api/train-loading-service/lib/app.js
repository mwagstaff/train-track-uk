import cors from "cors";
import express from "express";
import { fileURLToPath } from "node:url";

const adminPagePath = fileURLToPath(new URL("../public/admin.html", import.meta.url));

async function mapWithConcurrency(items, concurrency, operation) {
  const results = new Array(items.length);
  let index = 0;
  async function worker() {
    while (index < items.length) {
      const current = index;
      index += 1;
      results[current] = await operation(items[current]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
  return results;
}

const asyncRoute = (handler) => (req, res, next) => {
  Promise.resolve(handler(req, res, next)).catch(next);
};

export function createApp({ resolver, health, metrics, maxBatchSize }) {
  const app = express();
  app.disable("x-powered-by");
  app.use(cors());
  app.use(express.json({ limit: "128kb" }));
  app.use(metrics.middleware);

  app.get("/health/live", (_req, res) => {
    res.json({ live: true, checkedAt: new Date().toISOString() });
  });

  app.get("/health/ready", (_req, res) => {
    const status = health.status();
    res.status(status.ready ? 200 : 503).json(status);
  });

  app.get("/health/feed", (_req, res) => {
    const status = health.status();
    res.status(status.feed.healthy ? 200 : 503).json(status.feed);
  });

  app.get("/metrics", asyncRoute(async (_req, res) => {
    res.set("Content-Type", metrics.registry.contentType);
    res.send(await metrics.registry.metrics());
  }));

  app.get("/admin", (_req, res) => {
    res.set("Cache-Control", "no-cache");
    res.sendFile(adminPagePath);
  });

  app.get("/api/v1/admin/services", asyncRoute(async (_req, res) => {
    res.set("Cache-Control", "no-store");
    res.json({ services: await resolver.listActiveServices() });
  }));

  app.post("/api/v1/loading_details/batch", asyncRoute(async (req, res) => {
    const services = req.body?.services;
    if (!Array.isArray(services)) return res.status(400).json({ error: "services must be an array" });
    if (services.length > maxBatchSize) return res.status(413).json({ error: `Maximum batch size is ${maxBatchSize}` });
    const resolved = await mapWithConcurrency(services, 4, async (request) => {
      try {
        return await resolver.resolve(request);
      } catch (error) {
        return { status: "upstream_error", error: error.message };
      }
    });
    const response = {};
    services.forEach((request, index) => {
      if (request?.serviceID) response[request.serviceID] = resolved[index];
    });
    return res.json({ services: response });
  }));

  app.get("/api/v1/loading_details/rid/:rid", asyncRoute(async (req, res) => {
    const result = await resolver.resolveRid(req.params.rid, req.query.scheduledDeparture);
    res.status(result.status === "invalid" ? 400 : 200).json(result);
  }));

  app.get("/api/v1/loading_details/:serviceID", asyncRoute(async (req, res) => {
    const hasContext = req.query.from && req.query.to && req.query.scheduledDeparture;
    const result = hasContext
      ? await resolver.resolve({
        serviceID: req.params.serviceID,
        from: req.query.from,
        to: req.query.to,
        scheduledDeparture: req.query.scheduledDeparture,
        destinationCRS: req.query.destinationCRS,
        length: req.query.length ? Number(req.query.length) : undefined,
      })
      : await resolver.resolveCachedServiceID(req.params.serviceID);
    const statusCode = result.status === "mapping_context_required" ? 422 : result.status === "invalid" ? 400 : 200;
    res.status(statusCode).json(result);
  }));

  app.use((error, _req, res, _next) => {
    console.error("[http]", error?.message ?? error);
    res.status(500).json({ error: "Internal server error" });
  });

  return app;
}
