import SwiftUI

/// The Regatta right-rail root view, gated by `RegattaFeatureFlag`.
/// Renders three collapsible sections — Brain, Fleet, and Memory.
/// The Brain section hosts ``BrainChatView`` driven by ``RegattaBrainViewModel``.
/// The Memory section hosts ``MemoryInspectorView`` driven by ``RegattaMemoryViewModel``.
struct RegattaRailView: View {
    @State private var brainViewModel = RegattaBrainViewModel()
    @State private var memoryViewModel = RegattaMemoryViewModel()

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                RegattaRailSection(
                    title: String(localized: "regatta.rail.section.brain", defaultValue: "Brain"),
                    symbolName: "cpu"
                ) {
                    BrainChatView(viewModel: brainViewModel)
                }

                RegattaRailSection(
                    title: String(localized: "regatta.rail.section.fleet", defaultValue: "Fleet"),
                    symbolName: "sailboat"
                ) {
                    RegattaFleetSectionView()
                }

                RegattaRailSection(
                    title: String(localized: "regatta.rail.section.memory", defaultValue: "Memory"),
                    symbolName: "books.vertical"
                ) {
                    MemoryInspectorView(viewModel: memoryViewModel)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("RegattaRailView")
        .onAppear {
            // Register with the manager so AppDelegate can tear down the
            // brain session on app quit.
            RegattaBrainManager.shared.viewModel = brainViewModel
        }
    }
}
