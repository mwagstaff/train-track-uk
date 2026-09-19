# Missing Clock House–Invergowrie journey, 19 September 2026

The 04:44–13:41 National Rail itinerary is present in the imported timetable and is feasible under the existing interchange allowances. It disappears because its early-morning Victoria–Euston link has mode `genericTransfer`, which the API and iOS request exclude. This affects the original router as well as RAPTOR.

## Reproduction

The production search started at 00:54:29 BST on 19 September, completed successfully in 259 ms, and returned five results. Its requested time was `2026-09-18T23:54:29.561Z`. Production and the local compact snapshot use dataset version `e9a2be699c4acf8c72f08a2c7edcf19cc950770ea1c5bd9c2502bd58b2400988`; deployed routing, contract and service files matched the local files.

Using the exact requested time, the default six-hour departure window, five-change ceiling and zero extra connection allowance reproduced every departure/arrival/change-count tuple on the screenshot:

| Departure | Arrival | Changes |
| --- | --- | --- |
| 05:59 | 14:39 | 5 |
| 05:59 | 15:20 | 4 |
| 06:29 | 15:20 | 5 |
| 06:29 | 16:22 | 3 |
| 06:38 | 16:22 | 4 |

The full local search completed without truncation and contained six results. The missing journey was absent from the full result set, rather than hidden by pagination. Production logs do not retain request-specific mode lists, connection allowances or truncation, so the screenshot and this matching reproduction establish the relevant default behaviour.

## Leg-by-leg evidence

All times are BST on Saturday 19 September 2026.

| Leg | Evidence in the snapshot |
| --- | --- |
| Clock House 04:44 → Kent House 04:53, walk | `ALF:646`, nine-minute WALK; four-minute Kent House boarding allowance makes the 04:57 train feasible. |
| Kent House 04:57 → Victoria 05:18 | Southeastern service `P86786`, present and active. |
| Victoria 05:33 → Euston 05:52, transfer | `ALF:1289`, nineteen-minute TRANSFER, Saturday window 00:01–06:29. |
| Euston 06:10 → Stirling 12:20 | Lumo service `Y14771`, present and active. |
| Stirling 12:43 → Invergowrie 13:41 | ScotRail service `C14717`, present and active. |

The parser maps source `M=TRANSFER` to `genericTransfer` (`api/train-track-api/lib/planner/parser.js:53`). The public `MODES` list only permits `rail`, `replacementBus`, `walk` and `tubeTransfer` (`contract.js:10`); normalisation also rejects an explicitly requested `genericTransfer`. iOS sends that same four-mode list explicitly (`JourneyPlannerModels.swift:360`).

For the 05:18 arrival at Victoria, enabling the supplied TRANSFER gives:

- 15 minutes to leave Victoria: ready to move at 05:33.
- 19 minutes movement: Euston at 05:52.
- 15 minutes Euston boarding allowance: ready at 06:07.
- The 06:10 train is therefore feasible with three minutes remaining.

Without `genericTransfer`, the first permitted Saturday Tube link (`ALF:1292`) starts moving at 06:30 and makes the passenger ready at 06:59, missing the train. The National Rail screenshot labels the earlier leg “Transfer” and advises taxi or night bus while the Underground is closed.

## Controlled check and next change

An offline check added only `genericTransfer` to the internal request's allowed modes, bypassing the public normaliser for diagnosis. No timetable, train times, interchange allowances or routing algorithm changed. RAPTOR then returned **04:44–13:41 as the first result**, using the exact National Rail trains and transfer, and its independent itinerary validator passed.

The pre-optimisation RAPTOR implementation produced exactly the same complete results as the current implementation with the existing mode list. The original router also missed the early itinerary. This is a supported-mode gap, rather than a regression from the CPU optimisations, a timeout, missing timetable data or an initial-walk defect.

The follow-up implementation should support supplied `genericTransfer` links in both API and iOS requests and label them clearly as transfers, preserving the source operating windows and allowances. They must not be relabelled as Tube services: these records do not provide a scheduled bus/taxi service or guarantee ticket acceptance. The existing iOS fallback heading already says “Transfer”, and the routing output already carries a warning about missing detailed local departures. Add API, routing and client regression coverage for this itinerary when enabling the mode.

Keep the standalone router and connection defaults consistent with the API. Deploy server support before the client starts sending the additional mode; the current server rejects it. No timetable reimport is required. Existing cursors contain explicit mode lists, so strictly additive support can retain their original semantics; reinterpreting existing mode lists would instead require expiring affected cursors.

Our existing change-count policy would describe the recovered itinerary as three changes: three train boardings plus one non-walking transfer, minus one. National Rail displays four. The initial walk does not consume a boarding in our model; this separate presentation difference does not explain the missing journey.

No application behaviour or production state was changed during this investigation. Reproduction scripts and full JSON evidence are in the ignored local directory `api/train-track-api/var/planner/clk-ing-investigation-2026-09-19/` (`reproduce.mjs`, `reproduction.json`, `counterfactual.mjs`, `counterfactual.json`).

## Implemented follow-up

Following the request to enable these connections, `genericTransfer` is now included in the shared API/router/connection defaults and the iOS request. Explicit mode exclusions and existing cursor permissions remain unchanged. This implementation is local; deploy API support before releasing the updated app.

Journeys containing an unspecified transfer show a warning triangle and “Check transfer options” in their results row. The affected transfer section repeats that warning and explains:

> No specific transport service is listed for this transfer.
>
> Check your options before travelling. In London, you may need a taxi or night bus when the Tube is closed.

The London qualification matters because the snapshot also supplies generic links outside London. Ordinary train, replacement-bus, walking and Tube legs do not acquire this warning, and a transfer with available detailed local directions does not need it. Warning text remains available to VoiceOver, alongside the icon.

Verification:

- The normalised default RAPTOR request against the full production-version snapshot now returns 04:44–13:41 first. Journey details retain the transfer and warning. Explicitly excluding `genericTransfer` restores the previous earliest arrival of 14:39. Evidence: `verify-enabled.mjs` and `enabled-public-response.json` in the investigation directory.
- 635 planner tests passed, with two optional checks skipped. The new fixture verifies the exact itinerary in both routers, link windows, weekday, station allowances, extra buffers, mode exclusions and existing cursors. Log: `/tmp/traintrack-generic-transfer-planner-tests.log`.
- All 62 iOS planner unit tests passed, including default request encoding, generic-transfer decoding, warning eligibility and resolved local directions.
- Three focused UI tests passed across runs: normal-size results/details; largest Dynamic Type in actual simulator Dark Mode; and absence of the warning on ordinary and detailed Tube transfers. Screenshots were reviewed, and the positive cases passed hit-region accessibility audits. The large-text test was corrected to scroll to lazily rendered rows and use an ordinary button tap.
- A broader existing details/map UI test hit its unrelated “Scheduled times only” caption assertion and subsequent map checks; that run was stopped. The focused warning checks passed, but this is not a claim that the full existing UI suite passes.

The normal-size captures are under `/tmp/traintrack-generic-transfer-light-attachments/`; the final large-text Dark Mode result bundle and captures are `/tmp/traintrack-generic-transfer-dark-verified.xcresult` and `/tmp/traintrack-generic-transfer-dark-verified-attachments/`.
