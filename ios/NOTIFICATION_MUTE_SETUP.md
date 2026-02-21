# Notification Mute Debugging & Setup

## Problem
Notifications continue to arrive after geofence arrival detection triggers the "mute on arrival" feature.

## Solution
This update implements a **dual-layer approach**:

1. **Backend mute** - Send mute request to API (existing, now with better logging)
2. **Client-side filtering** - Notification Service Extension filters notifications locally (NEW)
3. **In-app debug logs** - View what's happening without Xcode (NEW)

## Setup Instructions

### 1. Add Notification Service Extension to Xcode

The Notification Service Extension files have been created, but you need to add them to your Xcode project:

1. Open `TrainTrack UK.xcodeproj` in Xcode
2. Right-click on the project root and select "Add Files to TrainTrack UK"
3. Navigate to `NotificationServiceExtension` folder
4. Select both files:
   - `NotificationService.swift`
   - `Info.plist`
5. Click "Add"

Alternatively, create a new Notification Service Extension target:

1. File → New → Target
2. Select "Notification Service Extension"
3. Name it "NotificationServiceExtension"
4. Bundle Identifier: `dev.skynolimit.traintrack.NotificationServiceExtension`
5. Replace the generated `NotificationService.swift` with the one provided

### 2. Configure App Groups

Both the main app and the extension need to share data via App Groups:

1. Select the main app target → Signing & Capabilities
2. Click "+ Capability" → App Groups
3. Add group: `group.dev.skynolimit.traintrack`
4. Select the NotificationServiceExtension target → Signing & Capabilities
5. Click "+ Capability" → App Groups
6. Add the same group: `group.dev.skynolimit.traintrack`

### 3. Update Backend Notification Payload

The backend needs to add `"mutable-content": 1` to the APNs payload so the extension can intercept:

In `fly/train-track-api/lib/notification-push-client.js`, update the payload:

```javascript
payload: {
    aps: {
        alert: { title, body },
        sound: 'default',
        'mutable-content': 1  // ADD THIS LINE
    }
}
```

### 4. Build and Test

1. Build the app with the new extension target
2. Install on your device
3. Set up a notification subscription for a nearby journey
4. When you arrive at the starting station, check:
   - You get the "Arrived at..." notification
   - Debug logs show mute request being sent
   - Subsequent notifications are filtered out

## Using Debug Logs

To view debug logs on your device without Xcode:

1. Open the app
2. Go to Preferences (DEBUG builds only)
3. Tap "View Debug Logs"
4. You'll see logs categorized by:
   - **Geofence**: Region entry events
   - **Mute**: Mute requests and status
   - **Network**: API responses
   - **Error**: Failures and warnings

5. Use "Share" button to export logs via AirDrop, Messages, etc.

## How It Works

### When you arrive at a station:

1. **Geofence triggers** (`NotificationGeofenceManager`)
   - iOS detects entry into 250m radius around station
   - Logs: "Entered region: tt_notify_mute:..."

2. **Local mute tracking**
   - Writes to shared UserDefaults: `mutedLegsToday[KTH-VIC] = "2026-02-03"`
   - This allows the extension to filter notifications immediately
   - Logs: "Marked leg KTH-VIC as muted locally"

3. **Send arrival notification**
   - Shows user confirmation: "Arrived at Kent House"

4. **Backend mute request**
   - Background URLSession sends POST to `/notifications/terminate`
   - Payload includes subscription ID, station codes, and date
   - Logs: "Sending mute request: {...}"
   - Response logged with status code

5. **Future notifications filtered**
   - Backend checks `isMutedToday()` before sending (if mute succeeded)
   - Extension checks shared UserDefaults before displaying (backup)
   - If muted: notification is silently discarded

### Extension Logic:

```swift
// Notification arrives from APNs
→ Extension intercepts (because mutable-content: 1)
→ Extract station codes from title ("Kent House → London Victoria")
→ Check shared UserDefaults: mutedLegsToday["KTH-VIC"] == "2026-02-03"?
→ If yes: return empty content (notification hidden)
→ If no: deliver notification as normal
```

## Troubleshooting

### Notifications still appearing?

Check debug logs for:

1. **"Entered geofence region"** - Did the geofence trigger?
   - If not: Check Location Services → Always Allow
   - Geofences may take a few minutes to activate after setup

2. **"Marked leg X-Y as muted locally"** - Was local mute saved?
   - If not: App Groups may not be configured correctly

3. **"Mute request completed with status: 200"** - Did backend accept it?
   - If 404: Subscription ID or station codes don't match backend
   - If 400: Invalid request parameters
   - If error: Network issue or API endpoint problem

4. **Extension not filtering** - Is it receiving notifications?
   - Check backend payload includes `"mutable-content": 1`
   - Extension needs to be properly signed and included in build

### Backend mute not working?

If the extension is filtering correctly but you want to debug the backend:

1. Check subscription data on backend matches what the app sends
2. Station codes must be uppercase: "KTH" not "kth"
3. Leg key format: "KTH-VIC" (from-to with hyphen)
4. Date format: "YYYY-MM-DD" in local timezone

## Files Modified

### New Files:
- `DebugLogStore.swift` - In-memory log storage
- `DebugLogView.swift` - UI to view/share logs
- `NotificationServiceExtension/NotificationService.swift` - Extension code
- `NotificationServiceExtension/Info.plist` - Extension config

### Modified Files:
- `NotificationGeofenceManager.swift` - Added logging and local mute tracking
- `PreferencesView.swift` - Added debug logs button

## Testing Checklist

- [ ] App Groups configured in both targets
- [ ] Extension target added and builds successfully
- [ ] Backend payload includes `"mutable-content": 1`
- [ ] Location Services set to "Always Allow"
- [ ] Notification subscription created for test journey
- [ ] Arrive at starting station (or simulate location)
- [ ] "Arrived at..." notification appears
- [ ] Debug logs show geofence entry and mute request
- [ ] Subsequent notifications do NOT appear
- [ ] Debug logs show mute status is active
