import AppIntents
import SwiftUI

struct SiriShortcutsSettingsView: View {
    @ObservedObject var routeStore: SiriRouteStore = .shared
    @State private var routeToRename: SiriSavedRoute?

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    SiriDefaultRoutePicker(routeStore: routeStore)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default route")
                        Text(routeStore.defaultRoute?.displayName ?? "Choose a route")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(routeStore.routes.isEmpty)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Default route")
                .accessibilityValue(defaultRouteAccessibilityValue)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("siri.default-route")

                if routeStore.defaultRouteID != nil && routeStore.defaultRoute == nil {
                    Text("Your previous default is no longer an available direct saved route. Choose another route to use “my next train”.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("My next train")
            } footer: {
                Text("Choose a direct route from Favourites or My Journeys. When both outward and return journeys are saved, Siri uses the nearer departure station when your location is known, or asks which direction you want. Journeys with changes are not included.")
            }

            Section {
                if routeStore.routes.isEmpty {
                    Text("Save a direct route in Favourites or My Journeys to choose a default and give it a name for Siri.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(routeStore.routes) { route in
                        Button {
                            routeToRename = route
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.displayName)
                                    .foregroundStyle(Color.primary)
                                if route.displayName != route.stationSummary {
                                    Text(route.stationSummary)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                        }
                        .accessibilityHint("Edit the name used for this saved route in Siri and Shortcuts")
                        .accessibilityIdentifier("siri.rename-route.\(route.id.uuidString)")
                    }
                }
            } header: {
                Text("Route names")
            } footer: {
                Text("Give a route a name such as “Work”. Saved outward and return journeys share one name. Renaming keeps existing shortcuts connected to the same route.")
            }

            Section("Try with Siri") {
                Text("“Use TrainTrack to get my next train”")
                if let route = routeStore.namedExampleRoute {
                    Text("“Get next trains for \(route.displayName) in TrainTrack”")
                        .accessibilityIdentifier("siri.named-route-example")
                }
                Text("“Check train departures in TrainTrack”")
                Text("For a general lookup, Siri asks for the departure and destination stations. If Siri opens Maps instead, try the personal shortcut below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Make a personal shortcut") {
                Text("In Shortcuts, create a shortcut and add a TrainTrack UK action. Choose “Get My Next Train” for your default route, or “Get Train Departures” and set both stations.")
                Text("To always use one direction, set “Departure station” in the default-route or saved-route action. Leave it blank to use the nearer end.")
                Text("Name the shortcut “TrainTrack next train”, then say “Hey Siri, TrainTrack next train”.")
                ShortcutsLink()
                Text("These actions are for iPhone, including Siri through AirPods. Siri may require you to unlock your iPhone according to your settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Siri & Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $routeToRename) { route in
            SiriRouteNameEditor(route: route, routeStore: routeStore)
        }
    }

    private var defaultRouteAccessibilityValue: String {
        guard let route = routeStore.defaultRoute else { return "Choose a route" }
        return route.displayName == route.stationSummary
            ? route.displayName : "\(route.displayName), \(route.stationSummary)"
    }
}

private struct SiriDefaultRoutePicker: View {
    @ObservedObject var routeStore: SiriRouteStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            routeButton(nil)
            ForEach(routeStore.routes) { route in
                routeButton(route)
            }
        }
        .navigationTitle("Default route")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func routeButton(_ route: SiriSavedRoute?) -> some View {
        let selected = routeStore.defaultRoute?.pairKey == route?.pairKey
        return Button {
            routeStore.setDefaultRoute(id: route?.id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route?.displayName ?? "Choose a route")
                        .foregroundStyle(Color.primary)
                    if let route, route.displayName != route.stationSummary {
                        Text(route.stationSummary)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityIdentifier(route.map { "siri.default-route.option.\($0.id.uuidString)" } ?? "siri.default-route.none")
    }
}

private struct SiriRouteNameEditor: View {
    let route: SiriSavedRoute
    let routeStore: SiriRouteStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Route name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("siri.route-name")
                    Text(route.stationSummary)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Saved outward and return journeys share this name. Leave it blank to use the station names.")
                }
            }
            .navigationTitle("Route name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        routeStore.setName(name, for: route.id)
                        dismiss()
                    }
                    .accessibilityIdentifier("siri.route-name.save")
                }
            }
            .onAppear { name = routeStore.name(for: route.id) }
        }
    }
}
