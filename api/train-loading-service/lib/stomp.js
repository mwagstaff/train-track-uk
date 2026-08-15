import net from "node:net";

function unescapeHeader(value) {
  const escapes = { r: "\r", n: "\n", c: ":", "\\": "\\" };
  return value.replace(/\\([rnc\\])/g, (_, escaped) => escapes[escaped]);
}

function escapeHeader(value) {
  return String(value).replace(/\\/g, "\\\\").replace(/\r/g, "\\r").replace(/\n/g, "\\n").replace(/:/g, "\\c");
}

export function encodeFrame(command, headers = {}, body = Buffer.alloc(0)) {
  const payload = Buffer.isBuffer(body) ? body : Buffer.from(body);
  const lines = [command];
  const shouldEscape = command !== "CONNECT" && command !== "CONNECTED";
  for (const [name, value] of Object.entries(headers)) {
    if (value !== undefined) {
      lines.push(shouldEscape ? `${escapeHeader(name)}:${escapeHeader(value)}` : `${name}:${value}`);
    }
  }
  if (payload.length > 0 && headers["content-length"] === undefined) {
    lines.push(`content-length:${payload.length}`);
  }
  return Buffer.concat([Buffer.from(`${lines.join("\n")}\n\n`), payload, Buffer.from([0])]);
}

export class StompFrameParser {
  constructor(onFrame, onHeartbeat = () => {}) {
    this.buffer = Buffer.alloc(0);
    this.onFrame = onFrame;
    this.onHeartbeat = onHeartbeat;
  }

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length > 0) {
      if (this.buffer[0] === 10) {
        this.buffer = this.buffer.subarray(1);
        this.onHeartbeat();
        continue;
      }

      const lfEnd = this.buffer.indexOf("\n\n");
      const crlfEnd = this.buffer.indexOf("\r\n\r\n");
      const headerEnd = lfEnd === -1 ? crlfEnd : crlfEnd === -1 ? lfEnd : Math.min(lfEnd, crlfEnd);
      if (headerEnd === -1) return;
      const separatorLength = headerEnd === crlfEnd ? 4 : 2;
      const [command, ...headerLines] = this.buffer.subarray(0, headerEnd).toString("utf8").replace(/\r/g, "").split("\n");
      const headers = {};
      for (const line of headerLines) {
        const separator = line.indexOf(":");
        if (separator !== -1) {
          headers[unescapeHeader(line.slice(0, separator))] = unescapeHeader(line.slice(separator + 1));
        }
      }

      const bodyStart = headerEnd + separatorLength;
      let bodyEnd;
      if (headers["content-length"] !== undefined) {
        const length = Number.parseInt(headers["content-length"], 10);
        if (!Number.isSafeInteger(length) || length < 0) throw new Error("Invalid STOMP content-length");
        bodyEnd = bodyStart + length;
        if (this.buffer.length <= bodyEnd) return;
        if (this.buffer[bodyEnd] !== 0) throw new Error("STOMP frame missing null terminator");
      } else {
        bodyEnd = this.buffer.indexOf(0, bodyStart);
        if (bodyEnd === -1) return;
      }

      const body = this.buffer.subarray(bodyStart, bodyEnd);
      this.buffer = this.buffer.subarray(bodyEnd + 1);
      this.onFrame({ command, headers, body });
    }
  }
}

const iso = (milliseconds) => milliseconds ? new Date(milliseconds).toISOString() : null;

export class DarwinStompClient {
  constructor(options) {
    this.options = options;
    this.socket = null;
    this.reconnectTimer = null;
    this.connectTimer = null;
    this.heartbeatTimer = null;
    this.watchdogTimer = null;
    this.stopped = true;
    this.reconnectDelay = 1_000;
    this.health = {
      state: "stopped",
      connectedAt: 0,
      lastDataAt: 0,
      lastHeartbeatAt: 0,
      lastFrameAt: 0,
      lastMessageAt: 0,
      lastSequence: null,
      sequenceGaps: 0,
      reconnectAttempts: 0,
      lastError: null,
    };
  }

  start() {
    if (!this.stopped) return;
    this.stopped = false;
    this.connect();
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.reconnectTimer);
    clearTimeout(this.connectTimer);
    clearInterval(this.heartbeatTimer);
    clearInterval(this.watchdogTimer);
    this.health.state = "stopped";
    if (this.socket && !this.socket.destroyed) {
      this.socket.write(encodeFrame("DISCONNECT"));
      this.socket.end();
    }
  }

  status(now = Date.now()) {
    const age = (value) => value ? Math.max(0, Math.floor((now - value) / 1_000)) : null;
    return {
      state: this.health.state,
      connectedAt: iso(this.health.connectedAt),
      lastDataAt: iso(this.health.lastDataAt),
      lastHeartbeatAt: iso(this.health.lastHeartbeatAt),
      lastFrameAt: iso(this.health.lastFrameAt),
      lastMessageAt: iso(this.health.lastMessageAt),
      transportAgeSeconds: age(this.health.lastDataAt),
      messageAgeSeconds: age(this.health.lastMessageAt),
      lastSequence: this.health.lastSequence,
      sequenceGaps: this.health.sequenceGaps,
      reconnectAttempts: this.health.reconnectAttempts,
      lastError: this.health.lastError,
    };
  }

  isHealthy(now = Date.now()) {
    const { transportStaleMs, messageStaleMs } = this.options;
    const referenceForMessages = this.health.lastMessageAt || this.health.connectedAt;
    return this.health.state === "subscribed"
      && now - this.health.lastDataAt <= transportStaleMs
      && now - referenceForMessages <= messageStaleMs;
  }

  setState(state) {
    this.health.state = state;
    this.options.onState?.(this.status());
  }

  connect() {
    if (this.stopped) return;
    this.setState("connecting");
    const parser = new StompFrameParser(
      (frame) => this.handleFrame(frame),
      () => {
        const now = Date.now();
        this.health.lastHeartbeatAt = now;
        this.health.lastDataAt = now;
      },
    );

    this.socket = net.createConnection({ host: this.options.host, port: this.options.port });
    this.connectTimer = setTimeout(() => {
      this.fail(`Connection attempt timed out after ${this.options.connectTimeoutMs}ms`);
    }, this.options.connectTimeoutMs);
    this.connectTimer.unref?.();
    this.socket.on("connect", () => {
      clearTimeout(this.connectTimer);
      this.socket.setKeepAlive(true, this.options.heartbeatMs);
      const headers = {
        "accept-version": "1.2,1.1",
        host: this.options.host,
        login: this.options.username,
        passcode: this.options.password,
        "heart-beat": `${this.options.heartbeatMs},${this.options.heartbeatMs}`,
      };
      if (this.options.clientId) headers["client-id"] = this.options.clientId;
      this.socket.write(encodeFrame("CONNECT", headers));
    });
    this.socket.on("data", (chunk) => {
      this.health.lastDataAt = Date.now();
      try {
        parser.push(chunk);
      } catch (error) {
        this.fail(`Protocol error: ${error.message}`);
      }
    });
    this.socket.on("error", (error) => {
      this.health.lastError = error.message;
      this.options.onError?.(error);
    });
    this.socket.on("close", () => this.handleClose());
  }

  handleFrame(frame) {
    const now = Date.now();
    this.health.lastFrameAt = now;
    if (frame.command === "CONNECTED") {
      this.health.connectedAt = now;
      this.health.lastDataAt = now;
      this.health.lastError = null;
      this.reconnectDelay = 1_000;
      const headers = {
        id: "train-loading-service",
        destination: this.options.destination,
        ack: "auto",
      };
      if (this.options.selector) headers.selector = this.options.selector;
      if (this.options.subscriptionName) headers["activemq.subscriptionName"] = this.options.subscriptionName;
      this.socket.write(encodeFrame("SUBSCRIBE", headers));
      this.setState("subscribed");
      this.startTimers();
      return;
    }

    if (frame.command === "MESSAGE") {
      this.health.lastMessageAt = now;
      this.trackSequence(frame.headers);
      this.options.onMessage?.(frame);
      return;
    }

    if (frame.command === "ERROR") {
      this.fail(frame.headers.message ?? frame.body.toString("utf8").trim() ?? "Broker error");
    }
  }

  trackSequence(headers) {
    const raw = headers.SequenceNumber ?? headers.sequenceNumber;
    const sequence = Number.parseInt(raw, 10);
    if (!Number.isSafeInteger(sequence)) return;
    const previous = this.health.lastSequence;
    if (Number.isSafeInteger(previous)) {
      const expected = previous === 9_999_999 ? 0 : previous + 1;
      if (sequence !== expected) {
        this.health.sequenceGaps += 1;
        this.options.onSequenceGap?.({ previous, expected, received: sequence });
      }
    }
    this.health.lastSequence = sequence;
  }

  startTimers() {
    clearInterval(this.heartbeatTimer);
    clearInterval(this.watchdogTimer);
    this.heartbeatTimer = setInterval(() => {
      if (this.socket && !this.socket.destroyed) this.socket.write("\n");
    }, this.options.heartbeatMs);
    this.watchdogTimer = setInterval(() => {
      if (this.health.state !== "subscribed") return;
      if (Date.now() - this.health.lastDataAt > this.options.transportStaleMs) {
        this.fail(`No broker traffic for ${this.options.transportStaleMs}ms`);
      }
    }, Math.min(this.options.heartbeatMs, 5_000));
    this.heartbeatTimer.unref?.();
    this.watchdogTimer.unref?.();
  }

  fail(message) {
    this.health.lastError = message;
    this.options.onError?.(new Error(message));
    this.socket?.destroy();
  }

  handleClose() {
    clearTimeout(this.connectTimer);
    clearInterval(this.heartbeatTimer);
    clearInterval(this.watchdogTimer);
    if (this.stopped) return;
    this.setState("disconnected");
    this.health.reconnectAttempts += 1;
    const jitter = Math.floor(Math.random() * Math.min(1_000, this.reconnectDelay / 2));
    const delay = this.reconnectDelay + jitter;
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.options.reconnectMaxMs);
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
    this.reconnectTimer.unref?.();
  }
}
