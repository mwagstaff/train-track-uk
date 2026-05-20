import SwiftUI
import UIKit

struct AboutView: View {
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "Version \(version)"
    }

    private var deviceIdentifier: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    private var feedbackURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "mike.wagstaff@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "TrainTrack UK feedback [\(deviceIdentifier)]")
        ]
        return components.url ?? URL(string: "mailto:mike.wagstaff@gmail.com")!
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TrainTrack UK")
                        .font(.title2).bold()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }

            Section("Developer") {
                Text("Developed by Mike Wagstaff")
                Link(destination: URL(string: "https://skynolimit.dev/")!) {
                    // Use globe icon to represent personal website
                    Label("Sky No Limit", systemImage: "globe")
                }
            }

            Section("Feedback") {
                Link(destination: feedbackURL) {
                    Label("Email Feedback", systemImage: "envelope")
                }
            }

            Section("Data sources") {
                Link(destination: URL(string: "https://www.nationalrail.co.uk/")!) {
                    Label("National Rail Enquiries", systemImage: "train.side.front.car")
                }
                Link(destination: URL(string: "https://github.com/davwheat/uk-railway-stations")!) {
                    Label("UK Railway Stations", systemImage: "building.columns")
                }
                Link(destination: URL(string: "https://github.com/trainline-eu/stations")!) {
                    Label("Stations - A Database of European Train Stations", systemImage: "globe.europe.africa")
                }
            }
        }
        .navigationTitle("About")
    }
}

#Preview {
    NavigationStack { AboutView() }
}
