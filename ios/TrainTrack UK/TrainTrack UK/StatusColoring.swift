import SwiftUI

// Centralized delay color rules used across the app
// Thresholds:
// - red: 5+ minutes late, or "Delayed"/"Cancelled"
// - yellow: 1–4 minutes late
// - green: on time (0 min)

func colorForDelay(estimated: String?, scheduled: String?) -> Color {
    guard let estRaw = estimated?.lowercased() else { return .secondary }
    if estRaw == "cancelled" || estRaw == "delayed" { return .red }
    guard let sch = scheduled else { return .secondary }

    let df = DateFormatter(); df.dateFormat = "HH:mm"
    if let s = df.date(from: sch), let e = df.date(from: estimated ?? "") {
        let mins = Calendar.current.dateComponents([.minute], from: s, to: e).minute ?? 0
        return colorForDelayMinutes(mins)
    }
    return .secondary
}

func colorForDelayMinutes(_ minutes: Int) -> Color {
    if minutes >= 5 { return .red }
    if minutes > 0 { return .yellow }
    return .green
}

func departureDelayMinutes(estimated: String?, scheduled: String?) -> Int? {
    let est = estimated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let sch = scheduled?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if est.isEmpty || sch.isEmpty { return nil }

    let lower = est.lowercased()
    if lower == "on time" { return 0 }
    if lower == "delayed" || lower == "cancelled" { return nil }

    let df = DateFormatter()
    df.dateFormat = "HH:mm"

    guard let s = df.date(from: sch), let e = df.date(from: est) else { return nil }
    var mins = Calendar.current.dateComponents([.minute], from: s, to: e).minute ?? 0
    // Handle day rollover (e.g. 23:58 -> 00:06 should be +8, not -1432).
    if mins < -12 * 60 { mins += 24 * 60 }
    return max(0, mins)
}
