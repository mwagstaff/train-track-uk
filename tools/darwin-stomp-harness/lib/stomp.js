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
  const shouldEscapeHeaders = command !== "CONNECT" && command !== "CONNECTED";

  for (const [name, value] of Object.entries(headers)) {
    lines.push(shouldEscapeHeaders ? `${escapeHeader(name)}:${escapeHeader(value)}` : `${name}:${value}`);
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

      const lfHeaderEnd = this.buffer.indexOf("\n\n");
      const crlfHeaderEnd = this.buffer.indexOf("\r\n\r\n");
      const headerEnd = lfHeaderEnd === -1 ? crlfHeaderEnd : crlfHeaderEnd === -1 ? lfHeaderEnd : Math.min(lfHeaderEnd, crlfHeaderEnd);
      if (headerEnd === -1) return;
      const headerSeparatorLength = headerEnd === crlfHeaderEnd ? 4 : 2;

      const headerText = this.buffer.subarray(0, headerEnd).toString("utf8").replace(/\r/g, "");
      const [command, ...headerLines] = headerText.split("\n");
      const headers = {};

      for (const line of headerLines) {
        const separator = line.indexOf(":");
        if (separator === -1) continue;
        headers[unescapeHeader(line.slice(0, separator))] = unescapeHeader(line.slice(separator + 1));
      }

      const bodyStart = headerEnd + headerSeparatorLength;
      const declaredLength = headers["content-length"];
      let bodyEnd;

      if (declaredLength !== undefined) {
        const length = Number.parseInt(declaredLength, 10);
        if (!Number.isSafeInteger(length) || length < 0) throw new Error("Invalid STOMP content-length header");
        bodyEnd = bodyStart + length;
        if (this.buffer.length <= bodyEnd) return;
        if (this.buffer[bodyEnd] !== 0) throw new Error("STOMP frame is missing its null terminator");
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

export function createStompSubscription(options) {
  const {
    host,
    port,
    username,
    password,
    destination,
    selector,
    onMessage,
    onState = () => {},
  } = options;

  let socket;
  let reconnectTimer;
  let heartbeatTimer;
  let stopped = false;
  let reconnectDelay = 1_000;

  const connect = () => {
    if (stopped) return;
    onState(`Connecting to ${host}:${port}`);

    const parser = new StompFrameParser((frame) => {
      if (frame.command === "CONNECTED") {
        reconnectDelay = 1_000;
        onState(`Connected; subscribing to ${destination}`);
        const headers = { id: "darwin-harness", destination, ack: "auto" };
        if (selector) headers.selector = selector;
        socket.write(encodeFrame("SUBSCRIBE", headers));

        clearInterval(heartbeatTimer);
        heartbeatTimer = setInterval(() => {
          if (!socket.destroyed) socket.write("\n");
        }, 10_000);
        return;
      }

      if (frame.command === "MESSAGE") {
        onMessage(frame);
        return;
      }

      if (frame.command === "ERROR") {
        const detail = frame.body.toString("utf8").trim();
        onState(`Broker error: ${frame.headers.message ?? detail ?? "unknown error"}`);
      }
    });

    socket = net.createConnection({ host, port });
    socket.on("connect", () => {
      socket.write(
        encodeFrame("CONNECT", {
          "accept-version": "1.2,1.1",
          host,
          login: username,
          passcode: password,
          "heart-beat": "10000,10000",
        }),
      );
    });
    socket.on("data", (chunk) => {
      try {
        parser.push(chunk);
      } catch (error) {
        onState(`Protocol error: ${error.message}`);
        socket.destroy();
      }
    });
    socket.on("error", (error) => onState(`Connection error: ${error.message}`));
    socket.on("close", () => {
      clearInterval(heartbeatTimer);
      if (stopped) return;
      onState(`Disconnected; retrying in ${reconnectDelay / 1_000}s`);
      reconnectTimer = setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 30_000);
    });
  };

  connect();

  return {
    stop() {
      stopped = true;
      clearTimeout(reconnectTimer);
      clearInterval(heartbeatTimer);
      if (socket && !socket.destroyed) {
        socket.write(encodeFrame("DISCONNECT"));
        socket.end();
      }
    },
  };
}
