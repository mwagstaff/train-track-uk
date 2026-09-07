# TrainTrack UK — App Store metadata

Suggested English (UK) copy for version 5. Prepared 5 September 2026.

## App name

TrainTrack UK

## Subtitle

Live departures & journey maps

## Promotional text

Live UK train departures, platforms, route maps, journey notifications and recorded journey history, with links to train operators' Delay Repay claim pages.

## Description

TrainTrack UK displays live UK rail information using National Rail data. It is free, with no adverts, subscriptions or in-app purchases.

Departures
• Scheduled and expected departure and arrival times.
• Platform numbers, delays, cancellations and replacement bus services when reported.
• Calling points and service information.

Saved journeys
• Favourite routes and return journeys.
• Multi-leg journeys with intermediate stations.
• Search and sorting of saved journeys.

Journey tracking
• An In Progress screen for the current journey.
• Railway route maps with calling points and estimated train positions.
• Live Activities and push notifications.
• Scheduled journey updates and Holiday Mode to pause scheduled updates.

Journey history
• Recorded journeys with departure and arrival information.
• Delay Repay indicators based on recorded delays and supported operator rules.
• Links to operators' claim pages and manual claim-status tracking.

Other features
• Home Screen widgets.
• Railway photo backgrounds.
• Light and dark appearance on iPhone and iPad.
• Optional local troubleshooting logs that can be viewed, cleared and shared.

Live information requires an internet connection and depends on the rail data available. Train positions on maps are estimates. Location permission is required for location-aware tracking; notifications require permission. Train operators determine Delay Repay eligibility. TrainTrack does not sell tickets or submit compensation claims.

## Keywords

rail,times,platform,commute,delay,repay,station,alerts,timetable,widget,railway,travel

## What's New in Version 5

• In Progress screen for active journeys.
• Railway route maps with calling points and estimated train positions.
• Journey history with Delay Repay links and claim-status tracking.
• Railway photo backgrounds.
• Fixes to journey completion, notification muting and app badge handling.
• Optional troubleshooting log recording, viewing and sharing.

## Other fields

| Field | Suggested value / action |
| --- | --- |
| Primary language | English (UK) |
| Primary category | Navigation — retain the existing category |
| Secondary category | Travel, if desired |
| Price | Free — retain existing pricing |
| Copyright | 2026 Mike Wagstaff |
| Marketing URL | https://skynolimit.dev/ |
| Support URL | https://skynolimit.dev/ — currently includes contact information; a dedicated TrainTrack support page would be clearer |
| Privacy policy URL | https://skynolimit.dev/privacy_policy |
| Version | 5 — current project value |
| Build | Current project value is 4. Check App Store Connect and increment before upload if already used for version 5. |
| Age rating | Complete Apple's questionnaire for the current app; the public listing currently shows 4+. |
| App Review contact | Supply the account owner's review contact details; email in the app is mike.wagstaff@gmail.com. Add the required telephone number privately in App Store Connect. |
| Sign-in required | No account/sign-in flow was found in the iOS app. |
| Release option | Manual release lets you choose when to publish after approval. |
| Accessibility labels | Declare only features verified against Apple's criteria; simulator screenshots are not an accessibility certification. |
| Export compliance | Complete the encryption questionnaire based on the shipped binary and its use of standard HTTPS; do not guess answers. |

## Suggested App Review notes

TrainTrack UK provides live UK rail departure information using National Rail data. No account is required. Internet access is required for live departures and maps.

To try the app, add East Croydon to Gatwick Airport or Luton to Bedford. Available services depend on the current timetable. Save a route as a favourite, then tap a departure to view its route map and service information. Use the play button on a saved journey to start journey updates. The In Progress tab appears when journey tracking is available.

Location access supports station detection and journey progress, including during an active journey in the background. Notification permission supports journey alerts. Actual station-arrival behaviour requires a physical journey or simulated location; the app remains useful for departure information without these permissions.

Journey history includes links to train operators' Delay Repay claim pages. TrainTrack does not sell tickets or submit compensation claims itself.

Optional troubleshooting logs are available in Profile → Preferences → Diagnostics. Recording is off by default in release builds. Users can enable, inspect, clear and share logs themselves. Development-only API switching, the journey simulator and server-audit controls are excluded from release builds.

## Privacy information to resolve before submission

The public App Store listing currently says **Data Not Collected**. The current iOS privacy manifest declares device identifiers, product interaction, coarse location and other diagnostic data, linked to the user for app functionality, with no tracking. These are inconsistent: review and update App Store Connect's privacy answers to reflect actual app and server behaviour.

The public privacy policy mentions device IDs, but does not clearly explain journey/location processing, notification data, diagnostic exports or retention and deletion. Update the policy to describe the actual implementation before submission. Precise GPS details can appear in user-shared troubleshooting logs; assess this explicitly when completing privacy answers. The manifest is evidence for review, not a substitute for checking backend retention and all third-party processing.

## Sources checked

- [Apple: platform version information and field limits](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Apple: screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [Current public app listing](https://apps.apple.com/us/app/traintrack-uk/id6504205950)
- [Current privacy policy](https://skynolimit.dev/privacy_policy)
- [Developer website](https://skynolimit.dev/)

The name and subtitle fit 30 characters, promotional text fits 170 characters, keywords fit 100 bytes, and the description fits 4,000 characters. Copy only the relevant field contents into App Store Connect.
