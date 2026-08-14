import assert from "node:assert/strict";
import test from "node:test";
import { encodeFrame, StompFrameParser } from "../lib/stomp.js";

test("parses content-length framed binary bodies containing null bytes", () => {
  const frames = [];
  const parser = new StompFrameParser((frame) => frames.push(frame));
  const body = Buffer.from([0x1f, 0x8b, 0x00, 0x01]);
  const encoded = encodeFrame("MESSAGE", { destination: "/topic/test" }, body);

  parser.push(encoded.subarray(0, 7));
  parser.push(encoded.subarray(7));

  assert.equal(frames.length, 1);
  assert.equal(frames[0].command, "MESSAGE");
  assert.deepEqual(frames[0].body, body);
});

test("accepts heartbeats between frames", () => {
  const frames = [];
  let heartbeats = 0;
  const parser = new StompFrameParser((frame) => frames.push(frame), () => heartbeats += 1);

  parser.push(Buffer.concat([Buffer.from("\n"), encodeFrame("CONNECTED", { version: "1.2" })]));

  assert.equal(heartbeats, 1);
  assert.equal(frames[0].command, "CONNECTED");
});

test("accepts CRLF framed broker responses", () => {
  const frames = [];
  const parser = new StompFrameParser((frame) => frames.push(frame));

  parser.push(Buffer.from("CONNECTED\r\nversion:1.2\r\n\r\n\0"));

  assert.equal(frames.length, 1);
  assert.equal(frames[0].headers.version, "1.2");
});
