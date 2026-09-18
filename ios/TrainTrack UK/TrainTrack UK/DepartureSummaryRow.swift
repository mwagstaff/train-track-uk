import SwiftUI

struct DepartureSummaryRow<Timing: View, Platform: View, Status: View, Details: View, Footer: View>: View {
    @ViewBuilder var timing: Timing
    @ViewBuilder var platform: Platform
    @ViewBuilder var status: Status
    @ViewBuilder var details: Details
    @ViewBuilder var footer: Footer
    var showsChevron = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    if dynamicTypeSize.isAccessibilitySize {
                        stackedHeader
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                timing.fixedSize(horizontal: true, vertical: false)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                platform
                                status.frame(minWidth: 86, alignment: .leading)
                            }
                            stackedHeader
                        }
                    }
                    details
                }
                footer
            }
            .padding(.trailing, showsChevron ? 20 : 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            timing
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    platform.fixedSize()
                    status.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    platform
                    status.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct JourneyTimesView: View {
    let departure: String
    let arrival: String
    var departureColor: Color = .primary
    var cancelled = false

    var body: some View {
        Text("\(Text(departure).fontWeight(.bold).foregroundColor(departureColor)) \(Text("→ \(arrival)").fontWeight(.regular).foregroundColor(.plannerSecondaryText))")
            .font(.title3)
            .monospacedDigit()
            .strikethrough(cancelled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(departure) → \(arrival)")
            .accessibilityIdentifier("journey.times")
    }
}

struct JourneyDurationBadge: View {
    let tag: JourneyDurationTag

    var body: some View {
        Text(tag.rawValue)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tag == .fastest ? Color.plannerOnTimeText : Color.plannerSecondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((tag == .fastest ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityLabel(tag == .fastest ? "Fastest journey" : "Slower than average journey")
            .accessibilityIdentifier("journey.duration.\(tag == .fastest ? "fastest" : "slower")")
    }
}
