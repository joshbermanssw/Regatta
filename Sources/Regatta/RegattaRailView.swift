import SwiftUI

/// The Regatta right-rail root view, gated by `RegattaFeatureFlag`.
/// Renders three collapsible sections — Brain, Fleet, and Memory.
/// The Brain section hosts ``BrainChatView`` driven by ``RegattaBrainViewModel``.
/// The Memory section hosts ``MemoryInspectorView`` driven by ``RegattaMemoryViewModel``.
///
/// ## Attach-tab seam
/// `contextProvider` is a read-only closure injected by the parent
/// (`RightSidebarPanelView`) that returns the active workspace's context
/// snapshot when called.  It is never called from `body` — only from a button
/// action inside ``BrainChatView`` — so it is safe under Swift 6 isolation
/// without mutation.
struct RegattaRailView: View {
    /// Returns the active workspace tab context on demand. `nil` when no
    /// workspace is selected or when the parent cannot supply context.
    ///
    /// The closure is `@MainActor`-isolated because `TabManager.selectedWorkspace`
    /// (the source of truth) is also main-actor-bound.
    let contextProvider: (@MainActor () -> AttachedTabContext?)?

    @State private var brainViewModel = RegattaBrainViewModel()
    @State private var memoryViewModel = RegattaMemoryViewModel()
    @State private var fleetViewModel = RegattaFleetViewModel()

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                RegattaRailSection(
                    title: String(localized: "regatta.rail.section.brain", defaultValue: "Brain"),
                    symbolName: "cpu"
                ) {
                    BrainChatView(viewModel: brainViewModel, contextProvider: contextProvider)
                }

                RegattaRailSection(
                    title: String(localized: "regatta.rail.section.fleet", defaultValue: "Fleet"),
                    symbolName: "sailboat"
                ) {
                    FleetSectionView(viewModel: fleetViewModel, contextProvider: contextProvider)
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
