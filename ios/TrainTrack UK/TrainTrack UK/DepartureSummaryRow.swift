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
                        timing
                        HStack(spacing: 12) {
                            platform
                            status
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 8)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            timing.frame(maxWidth: .infinity, alignment: .leading)
                            platform
                            status.frame(minWidth: 86, alignment: .leading)
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
}
