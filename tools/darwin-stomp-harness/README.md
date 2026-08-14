# Darwin STOMP harness

A small, read-only command-line client for inspecting Darwin Push Port v16 train
formation and coach-loading updates. It is intentionally separate from the main
Train Track API.

## Set up

Requires Node.js 20 or newer.

```bash
cd tools/darwin-stomp-harness
npm install
cp .env.example .env
```

Put the **Darwin Topic Information** username and password from National Rail
Data Portal's **My Feeds** page into `.env`. Do not use the FTP/SFTP credentials.
The repository ignores `.env` files.

## Run

The most reliable workflow is to copy the `rid` from an LDBSVWS staff departure
response and listen for that exact Darwin service:

```bash
npm start -- --rid 202608147401272
```

Multiple RIDs can be comma-separated or supplied with repeated `--rid` options.
Other useful modes are:

```bash
# Southeastern services whose schedule update has been observed since startup
npm start -- --toc SE

# All operators, formatted for humans
npm start -- --all

# Exact RID as newline-delimited JSON, stopping after 10 matching events
node harness.js --rid 202608147401272 --json --limit 10

# Raw decompressed XML for matching messages, stopping after five minutes
npm start -- --rid 202608147401272 --raw --duration 300
```

When piping JSON into another tool, invoke `node harness.js` directly (or use
`npm start --silent`). `npm start` normally writes its lifecycle banner to
standard output, which would otherwise make a JSON parser such as `jq` fail.

The default is `--toc SE`. The tool subscribes only to schedule (`SC`), schedule
formation (`SF`), and loading (`LO`) message types to keep the stream manageable.

## How the correlation works

- The staff departure-board response and Darwin Push Port identify the service
  with the same `rid`. Treat it as an opaque string.
- A `schedule` event maps that `rid` to a TOC (`SE` for Southeastern), UID, and
  headcode.
- `scheduleFormations` maps the `rid` to one or more formation IDs (`fid`) and
  their ordered coaches.
- `formationLoading` identifies both `rid` and `fid`, then gives a 0–100 loading
  value per coach at one TIPLOC.

Because Push Port is a stream of changes rather than a query API, starting the
harness does not guarantee an immediate formation or loading event. Exact RID
filtering is reliable when an update arrives. TOC filtering is best-effort: a
formation received before this process has observed its schedule cannot yet be
identified as Southeastern. Use `--all` while exploring if necessary.

Loading data is operator-supplied and may be absent, partial, or explicitly
cleared. The harness reports empty `formationLoading` elements as `cleared`.

## Verify

```bash
npm test
```

The tests cover gzip decoding, namespaced XML, binary-safe STOMP framing, RID/TOC
filtering, and formation/loading correlation without connecting to the broker.

## Reference

- [Darwin Push Port](https://wiki.openraildata.com/index.php/Darwin:Push_Port)
- [Darwin formations](https://wiki.openraildata.com/index.php/Darwin:Formations)
- [Darwin train loading](https://wiki.openraildata.com/index.php/Darwin:Train_Loading)
- [RID](https://wiki.openraildata.com/index.php/RID)
