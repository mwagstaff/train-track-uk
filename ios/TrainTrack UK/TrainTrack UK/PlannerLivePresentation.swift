import SwiftUI

enum PlannerLivePresentation {
    static func hasTimingEvidence(_ live: PlannerLiveAnnotation) -> Bool {
        live.departure != nil || live.arrival != nil || live.isCancelled || live.isDelayed
            || live.partCancelled == true || live.status == "partCancelled" || live.status == "onTime"
    }

    static func timingEvidence(for journey: PlannedJourney) -> [PlannerLiveAnnotation] {
        journey.legs.flatMap { leg in
            ([leg.live] + (leg.callingPoints ?? []).map(\.live)).compactMap { $0 }
        }.filter(hasTimingEvidence)
    }

    static func hasExpiredEvidence(for journey: PlannedJourney, context: PlannerLiveContext?, at now: Date) -> Bool {
        timingEvidence(for: journey).contains { annotation in
            if let updated = annotation.updatedAt { return now.timeIntervalSince(updated) >= 90 }
            if let expires = context?.expiresAt { return expires <= now }
            return context?.updatedAt.map { now.timeIntervalSince($0) >= 90 } ?? false
        }
    }

    static func context(for journey: PlannedJourney, from context: PlannerLiveContext?, at now: Date) -> PlannerLiveContext? {
        guard let context, timingEvidence(for: journey).isEmpty,
              journey.legs.contains(where: { $0.kind == "vehicle" && $0.mode == "rail" }) else { return context }
        let outsideWindow = journey.departure > now.addingTimeInterval(Double(context.windowHours ?? 4) * 3600)
        return PlannerLiveContext(mode: context.mode, status: outsideWindow ? "outsideWindow" : "unavailable",
            windowHours: context.windowHours, warnings: context.warnings)
    }

    static func title(for live: PlannerLiveAnnotation) -> String {
        if live.isCancelled { return "Cancelled" }
        if live.isDelayed { return "Delayed" }
        if live.partCancelled == true || live.status == "partCancelled" { return "Part cancelled" }
        if live.status == "onTime" { return "On time" }
        return "Live status unknown"
    }

    static func warnings(for journey: PlannedJourney) -> [String] {
        visibleWarnings((journey.warnings ?? []) + journey.legs.flatMap {
            ($0.localJourney?.travelNotes ?? []) + ($0.live?.warnings ?? []) + ($0.warnings ?? [])
        })
    }

    static func visibleWarnings(_ values: [String]) -> [String] {
        // Older servers include this information in warnings. The transfer's
        // detail section already explains its scheduled allowance neutrally.
        unique(values).filter {
            $0 != "This is a supplied generic transfer; detailed local departures and stops are not available."
        }
    }

    static func onTimeSummary(for journey: PlannedJourney) -> String? {
        let trains = journey.legs.filter { $0.kind == "vehicle" && $0.mode == "rail" }
        let confirmed = trains.filter { leg in
            guard let live = leg.live else { return false }
            return live.status == "onTime" && !live.isCancelled && !live.isDelayed
                && live.partCancelled != true && live.departure != nil && live.arrival != nil
        }.count
        guard confirmed > 0 else { return nil }
        let hasOtherDisruption = journey.legs.contains { leg in
            guard let live = leg.live else { return false }
            return live.isCancelled || live.isDelayed || live.partCancelled == true || live.status == "unknown"
        }
        if confirmed == trains.count && !hasOtherDisruption {
            return trains.count == 1 ? "Train on time" : "All trains on time"
        }
        return "\(confirmed) of \(trains.count) trains confirmed on time"
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct PlannerLiveBadge: View {
    let live: PlannerLiveAnnotation

    var body: some View {
        let title = PlannerLivePresentation.title(for: live)
        VStack(alignment: .leading, spacing: 4) {
            if live.isCancelled {
                Label(title, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.weight(.semibold))
            } else if live.isDelayed || live.partCancelled == true || live.status == "partCancelled" {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.yellow, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Label(title, systemImage: live.status == "onTime" ? "checkmark.circle" : "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(live.status == "onTime" ? Color.green : Color.secondary)
            }
            if !live.isCancelled && live.isDelayed && live.status == "unknown" {
                Text("Some live times are unknown").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PlannerLiveContextView: View {
    let live: PlannerLiveContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let live {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: live.mode == "ignore" || live.status == "outsideWindow" ? "calendar" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(Color.plannerActionText)
                        .accessibilityHidden(true)
                    Text(title(live))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if live.mode == "ignore" {
                    Text("Journey times use the timetable. Live disruption warnings are still shown.")
                        .font(.caption)
                }
                if live.status == "unavailable" {
                    Text("Live updates could not be checked. These times do not confirm that trains are running on time.")
                        .font(.caption)
                } else if live.status == "partial" {
                    Text("Some trains could not be checked. Scheduled times are shown where live times are unavailable.")
                        .font(.caption)
                } else if live.status == "outsideWindow" {
                    Text("Live updates cover journeys in the next \(live.windowHours ?? 4) hours.")
                        .font(.caption)
                }
                if let updatedAt = live.updatedAt {
                    Text("Live information checked \(PlannerTime.display(updatedAt))")
                        .font(.caption).foregroundStyle(Color.primary.opacity(0.65))
                }
                if let expiresAt = live.expiresAt, expiresAt < Date() {
                    Label("Live information may be out of date. Search again for an update.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                ForEach(PlannerLivePresentation.visibleWarnings(live.warnings ?? []), id: \.self) { warning in
                    Text(warning).font(.caption)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "calendar")
                        .foregroundStyle(Color.plannerActionText)
                        .accessibilityHidden(true)
                    Text("Scheduled times only")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Live updates are not available for this search.").font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func title(_ live: PlannerLiveContext) -> String {
        if live.mode == "ignore" { return "Using scheduled times" }
        switch live.status {
        case "live": return "Using live times"
        case "partial": return "Some live times unavailable"
        case "outsideWindow": return "Scheduled times only"
        default: return "Live times unavailable"
        }
    }
}

struct PlannerEventTimeView: View {
    let time: Date
    let scheduled: Date?
    let expected: Date?
    let cancelled: Bool
    var includeDate = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(PlannerTime.display(time, includeDate: includeDate))
                .monospacedDigit()
                .foregroundStyle(cancelled ? Color.red : Color.primary)
                .strikethrough(cancelled, color: .red)
            if let scheduled, abs(time.timeIntervalSince(scheduled)) >= 30 {
                Text("Scheduled \(PlannerTime.display(scheduled, includeDate: includeDate))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !cancelled, let expected, abs(expected.timeIntervalSince(time)) >= 30 {
                Text("Expected \(PlannerTime.display(expected, includeDate: includeDate))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
