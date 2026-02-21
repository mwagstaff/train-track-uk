import SwiftUI

struct DeepLinkJourneySheet: View {
    let group: JourneyGroup
    @EnvironmentObject var depStore: DeparturesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            JourneyDetailsView(group: group)
                .environmentObject(depStore)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
