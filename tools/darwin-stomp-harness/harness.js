#!/usr/bin/env node

import dotenv from "dotenv";
import { createStompSubscription } from "./lib/stomp.js";
import {
  decodeDarwinBody,
  eventMatches,
  FormationTracker,
  formatEvent,
  parseDarwinMessage,
} from "./lib/darwin.js";

dotenv.config({ quiet: true });

function usage() {
  console.log(`Usage: node harness.js [options]

Inspect live Darwin schedule, formation, and coach-loading updates.

Options:
  --rid RID[,RID...]  Show exact RID(s) from LDBSVWS; may be repeated
  --toc CODE          Show services learned to have this TOC (default: SE)
  --all               Show all operators
  --json              Emit newline-delimited JSON events
  --raw               Emit matching raw XML messages
  --limit N           Stop after N matching events
  --duration SECONDS  Stop after this many seconds
  --help               Show this help

Credentials are read from DARWIN_USERNAME and DARWIN_PASSWORD. Connection
defaults can be overridden with DARWIN_HOST, DARWIN_PORT, and DARWIN_TOPIC.`);
}

function parseArguments(argv) {
  const options = { rids: new Set(), toc: "SE", all: false, json: false, raw: false };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[index + 1];
    if (argument === "--help") options.help = true;
    else if (argument === "--all") options.all = true;
    else if (argument === "--json") options.json = true;
    else if (argument === "--raw") options.raw = true;
    else if (argument === "--rid" && value) {
      value.split(",").filter(Boolean).forEach((rid) => options.rids.add(rid));
      index += 1;
    } else if (argument === "--toc" && value) {
      options.toc = value.toUpperCase();
      index += 1;
    } else if (argument === "--limit" && value) {
      options.limit = Number.parseInt(value, 10);
      index += 1;
    } else if (argument === "--duration" && value) {
      options.duration = Number.parseInt(value, 10);
      index += 1;
    } else {
      throw new Error(`Unknown or incomplete option: ${argument}`);
    }
  }

  if (options.json && options.raw) throw new Error("Choose either --json or --raw, not both");
  if (options.limit !== undefined && (!Number.isSafeInteger(options.limit) || options.limit < 1)) throw new Error("--limit must be a positive integer");
  if (options.duration !== undefined && (!Number.isSafeInteger(options.duration) || options.duration < 1)) throw new Error("--duration must be a positive integer");
  return options;
}

let options;
try {
  options = parseArguments(process.argv.slice(2));
} catch (error) {
  console.error(error.message);
  usage();
  process.exit(1);
}

if (options.help) {
  usage();
  process.exit(0);
}

const username = process.env.DARWIN_USERNAME;
const password = process.env.DARWIN_PASSWORD;
if (!username || !password) {
  console.error("Set DARWIN_USERNAME and DARWIN_PASSWORD (copy .env.example to .env for local use).");
  process.exit(1);
}

const connection = {
  host: process.env.DARWIN_HOST ?? "darwin-dist-44ae45.nationalrail.co.uk",
  port: Number.parseInt(process.env.DARWIN_PORT ?? "61613", 10),
  destination: process.env.DARWIN_TOPIC ?? "/topic/darwin.pushport-v16",
};
const selector = "MessageType IN ('SC','SF','LO')";
const tracker = new FormationTracker();
let matchedCount = 0;
let subscription;

const stop = () => {
  subscription?.stop();
  process.exit(0);
};

const filterDescription = options.all
  ? "all operators"
  : options.rids.size > 0
    ? `RID ${[...options.rids].join(", ")}`
    : `TOC ${options.toc} (learned from schedule updates observed after startup)`;
console.error(`Darwin harness: ${filterDescription}; message types SC/SF/LO. Press Ctrl+C to stop.`);

subscription = createStompSubscription({
  ...connection,
  username,
  password,
  selector,
  onState: (message) => console.error(message),
  onMessage: (frame) => {
    try {
      const xml = decodeDarwinBody(frame.body);
      const events = parseDarwinMessage(xml, frame.headers).map((event) => tracker.enrich(event));
      const matches = events.filter((event) => eventMatches(event, options));
      if (matches.length === 0) return;

      if (options.raw) console.log(xml.trim());
      else for (const event of matches) console.log(options.json ? JSON.stringify(event) : formatEvent(event));

      matchedCount += matches.length;
      if (options.limit && matchedCount >= options.limit) stop();
    } catch (error) {
      console.error(`Could not decode Darwin message: ${error.message}`);
    }
  },
});

process.on("SIGINT", stop);
process.on("SIGTERM", stop);
if (options.duration) setTimeout(stop, options.duration * 1_000);
