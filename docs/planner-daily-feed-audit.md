# Daily timetable feed audit — 18 September 2026

## Decision

The supplied daily package is a structurally complete **update package**, not a complete timetable. Do not replace the monthly snapshot with it, or apply it directly to the existing sequence 939 snapshot and advertise the result as current or gap-free.

The official [RSPS5046 P-04-02 specification](https://www.rspaccreditation.org/downloadPublic.php?did=c5VkXAQOgMj8q024cALYymTpxTFaroiwLL7mvDA0A3UB5FJKuO), §4, defines CFA as an update to MCA. The daily package combines CFA changes with full reference/supplementary files. §7.6 says new daily recipients receive an initial full refresh. This is a delta feed, not a standalone or cumulative full extract.

Obtain a current full refresh, then process every subsequent daily update in order. Alternatively obtain the missing update chain from sequence 940 through 961 before applying 962. A matching sequence 962 full refresh would avoid needing that historical chain.

## Scope and method

Read-only comparison of:

- `api/train-track-api/resources/timetable_full`: sequence 939, manifest generated 25 August 2026.
- `api/train-track-api/sample_data/timetable_update`: sequence 962, manifest generated 17 September 2026.
- The existing `api/train-track-api/var/planner/snapshots/RJTTF939` metadata, validation and resolved services.

Both principal timetable files were streamed in full. Counts use their actual fixed-width records. CFA checks included header/trailer presence, 80-character widths, schedule/BX/origin/terminus ordering, date ranges, weekday masks, deletion/cancellation shape and normalized public chronology. Auxiliary MSN, ALF, TSI and ZTR were parsed with the existing parsers; manifest members and FLF/MSN footer counts were checked. No raw data, active snapshot or production state was changed.

These checks establish local structural integrity and identify discrepancies. They cannot certify completeness against the upstream authoritative timetable without a matching current full refresh.

## Measured comparison

| Measure | Monthly 939 | Daily 962 |
| --- | ---: | ---: |
| Package files | 9 | 9 |
| Total package bytes | 676,525,613 | 12,966,092 |
| Main timetable member | MCA | CFA |
| Main timetable bytes | 673,250,422 | 9,255,996 |
| Main timetable records | 8,210,371 | 112,878 |
| Basic schedule records | 455,794 | 5,949 |
| Distinct schedule UIDs | 235,275 | 5,572 |
| All LO/LI/LT calls | 7,256,616 | 101,083 |
| Activity-marked passenger calls | 4,128,057 | 57,449 |
| Association records | 5,634 | 55 |
| Earliest BS start | 17 May 2026 | 18 May 2026 |
| Latest BS end | 15 May 2027 | 15 May 2027 |

Passenger-call counts in this table are raw advertised activity matches, not the existing snapshot's supported/mapped-call count. The CFA's normalized passenger-call count also equals 57,449. Matching end dates do not imply matching service coverage: existing schedules whose dates extend into 2027 need not appear in a one-day change file.

### Update operations and STP

| Transaction | Schedules | Associations |
| --- | ---: | ---: |
| New (`N`) | 3,403 | 38 |
| Revise (`R`) | 1,793 | 2 |
| Delete (`D`) | 753 | 15 |

The CFA's schedule STP indicators are 1,249 permanent (`P`), 2,246 overlay (`O`), 2,146 new STP (`N`) and 308 cancellation (`C`). Transaction `N` and STP `N` mean different things. Retain both; cancellation rows with no calls must not be discarded.

Schedule identity is UID + start date + STP indicator (§5.3.3.3 of [RSPS5046](https://www.rspaccreditation.org/downloadPublic.php?did=c5VkXAQOgMj8q024cALYymTpxTFaroiwLL7mvDA0A3UB5FJKuO)). Association identity has additional location/type fields (§5.3.4.6).

Using that schedule identity and processing the CFA in file order against the 939 baseline:

- 531 deletion targets and 184 revision targets are absent from the baseline.
- 4 new-schedule targets already exist in the baseline.
- These discrepancies remain after considering earlier operations within the CFA itself.

That is concrete evidence that simply combining these two supplied principal files is not a valid update chain. It does not imply the CFA itself is malformed.

The daily HD record has extract date 17 September 2026, update indicator `U`, current reference `DFTTISA` and previous reference `DFTTISZ`. The full HD has indicator `F` and historical dates. The latter is an explicitly documented full-refresh date quirk (§5.5.1.2), not evidence by itself of corrupt monthly data. Use manifest dates for freshness; do not demand that full-refresh HD dates match them.

## What would be lost by treating CFA as the full timetable?

The 939 snapshot resolves 22,995 supported passenger services for 18 September 2026. Of those, **22,256 (96.8%) have UIDs not mentioned anywhere in the CFA**. For 19 September the corresponding figures are 23,211 and 22,720 (97.9%). These are baseline services, not a claim about the correct current timetable after the missing updates.

For 18 September, the CFA contains only 69 BS operations whose supplied date/day masks include that date: 66 revisions, 1 deletion and 2 additions. Most of this daily file changes future dates.

Examples of baseline operator coverage missing from the CFA's UID list:

| Operator | Baseline services on 18 Sep | UIDs absent from CFA |
| --- | ---: | ---: |
| Northern (`NT`) | 2,833 | 2,700 |
| ScotRail (`SR`) | 2,282 | 2,252 |
| Southeastern (`SE`) | 1,820 | 1,673 |
| GWR (`GW`) | 1,733 | 1,711 |
| Southern (`SN`) | 1,698 | 1,669 |
| SWR (`SW`) | 1,620 | 1,588 |
| London Overground (`LO`) | 1,615 | 1,611 |
| West Midlands (`LM`) | 1,333 | 1,299 |
| Chiltern (`CH`) | 349 | 349 |
| c2c (`CC`) | 371 | 371 |
| Great Northern (`GN`) | 411 | 411 |
| Grand Central (`GC`) | 20 | 20 |

Absence from a daily change file is expected. It proves the small file is not an opportunity to reduce the complete search dataset by approximately 98%.

## Auxiliary files

All eight DAT-listed members exist. The seven non-CFA data members use `RJTTF962` names while DAT/CFA use `RJTTC962`; that mixture is normal for an update package.

| Auxiliary data | Monthly 939 | Daily 962 | Findings |
| --- | ---: | ---: | --- |
| MSN physical definitions | 3,299 | 3,301 | No TIPLOC definitions removed; 2 added and 2 changed |
| MSN aliases | 298 | 298 | Unchanged |
| ALF links | 4,209 | 4,640 | 107 old rows removed; 538 added |
| FLF link commands | 1,224 | 1,226 | 2 added |
| TSI rules | 35 | 35 | Identical data |
| ZTR schedules | 5,383 | 6,055 | Full supplementary refresh, not a delta |

The new MSN definitions are `KDRMSVR` / KDM and `CATZQPC` / QPC. Existing BEWDLEY and OKHMPIC definitions change interchange status. New FLF commands link KDM–KID and PLY–QPC. ALF changes include future dated transfer restrictions. Do not keep old auxiliary files merely because the rail changes file is small.

REJ contains no rejected-train entries in either sample; its data is identical. SET is identical apart from wrapper metadata. FLF and MSN declared footer record counts match the supplied files. The existing strict auxiliary parsers reported no issues for the daily sample.

## Actual limitations and anomalies

The CFA checks found no record-width, schedule-order, inverted-calendar or normalized-chronology failures. All 4,903 schedules with calls have a currently supported rail/replacement-bus mode; 9 have a nonblank holiday restriction. None has fewer than two mapped passenger calls.

However, **3 genuinely public timed calls do not map to any definition in the daily MSN**:

| UID | Variant dates | TIPLOC | Public arrival/departure | CFA line |
| --- | --- | --- | --- | ---: |
| G00667 (`XC`) | 21–22 Sep 2026 | PRNCSTG | 23:58 / 23:58 | 13,868 |
| W44831 (`AW`) | 21–22 Sep 2026 | EUSKJN | 23:57 / 00:01 | 19,146 |
| W44831 (`AW`) | 23–24 Sep 2026 | EUSKJN | 23:57 / 00:01 | 23,460 |

Their passenger activity codes and nonzero public timings survive the current time normalizer. These appear to be public-call annotations at non-station timing points, but that interpretation is not an upstream-confirmed correction. Do not invent a CRS mapping or claim the feed is entirely anomaly-free. The current importer records unmapped passenger diagnostics and removes those calls from routing.

The existing monthly snapshot is already a deliberately partial planner implementation. Its metadata reports 6,067 unmapped-call schedule diagnostics, 1,675 holiday-restricted schedules and 5,383 excluded ZTR schedules. For 18 September it excludes 588 running supplementary services and 118 running holiday-restricted variants; 7 conflicting UID groups are also excluded. A successful local validation report is not certification that all possible passenger journeys are represented.

## Safe import/optimization starting point

1. Bootstrap from a complete current MCA package. Continue optimizing the complete snapshot, not CFA as a replacement.
2. Keep a canonical import store with transaction/STP/calendar keys, reference-file state and the metadata needed to apply updates. Apply each daily feed atomically to a candidate copy; never mutate the active snapshot in place.
3. Require contiguous sequences (including 999→001 rollover), check the CFA previous-file reference where usable, reject missing revise/delete targets and duplicate new keys, and make repeated ingestion idempotent by sequence/content hash. On a gap, fetch the missing chain or a fresh full package.
4. Replace the daily full auxiliary members and rebuild a minimal routing projection. Preserve public time offsets, pickup/setdown restrictions, service/calendar identity, operator-dependent interchange rules and directed/date/time-sensitive transfer links.
5. Validate candidate coverage and representative-date/per-operator service counts before atomic activation. Report known exclusions; avoid describing a candidate as gap-free merely because files parse.

These are implementation recommendations derived from the measured local data and the update semantics, not claims that this audit enabled daily ingestion.
