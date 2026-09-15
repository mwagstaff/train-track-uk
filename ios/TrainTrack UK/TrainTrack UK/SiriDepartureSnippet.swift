import SwiftUI

struct SiriDepartureSnippet: View {
    let result: SiriLookupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.routeLabel)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            // Keep cancellation and uncertainty caveats visible alongside the selected options.
            Text(result.dialog)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if !result.departures.isEmpty {
                ForEach(Array(result.departures.prefix(3)), id: \.id) { departure in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            departure.transportLabel,
                            systemImage: departure.transportLabel.localizedCaseInsensitiveContains("bus") ? "bus.fill" : "tram.fill"
                        )
                        .font(.body.weight(.semibold))

                        if let expected = departure.expectedDeparture {
                            Text(departure.timingUncertain
                                  ? "Was due at \(SiriDisplayTime.format(expected))"
                                 : "Expected \(SiriDisplayTime.format(expected))")
                                .font(.body.weight(.semibold))
                            if expected != departure.scheduledDeparture {
                                Text("Scheduled \(SiriDisplayTime.format(departure.scheduledDeparture))")
                                    .font(.subheadline)
                            }
                        } else {
                            Text("Scheduled \(SiriDisplayTime.format(departure.scheduledDeparture))")
                                .font(.body.weight(.semibold))
                        }

                        Text(departure.statusLabel)
                            .font(.subheadline)
                        Text(departure.platform.map { "Platform \($0)" } ?? "Platform not confirmed")
                            .font(.subheadline)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
            }

            if !result.freshnessLabel.isEmpty {
                Text(result.freshnessLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }
}

#Preview("Departure snapshot") {
    SiriDepartureSnippet(result: siriSnippetPreview)
}

#Preview("Dark and large text") {
    SiriDepartureSnippet(result: siriSnippetPreview)
        .preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, .accessibility3)
}

private var siriSnippetPreview: SiriLookupResult {
    SiriLookupResult(
        dialog: "The 8:42 is delayed, but there isn't an expected departure time yet. The platform hasn't been announced.",
        routeLabel: "Kent House to London Victoria",
        departures: [SiriDeparture(
            id: "synthetic-preview-departure",
            originCRS: "KTH",
            originName: "Kent House",
            destinationCRS: "VIC",
            destinationName: "London Victoria",
            serviceID: "synthetic-preview-service",
            operatingDate: "2026-09-15",
            scheduledDeparture: Date(timeIntervalSince1970: 1_789_458_120),
            expectedDeparture: nil,
            platform: nil,
            statusLabel: "Delayed · No new time yet",
            transportLabel: "Train",
            freshnessLabel: "Synthetic preview",
            timingUncertain: true
        )],
        freshnessLabel: "Synthetic preview · This is a snapshot"
    )
}
