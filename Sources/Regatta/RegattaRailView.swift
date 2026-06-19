import SwiftUI

/// The Regatta right-rail root view, gated by `RegattaFeatureFlag`.
/// Renders three collapsible sections — Brain, Fleet, and Memory —
/// as empty shells. Content will be added in later Regatta slices.
struct RegattaRailView: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                RegattaRailSection(
                    title: String(localized: "regatta.rail.section.brain", defaultValue: "Brain"),
                    symbolName: "cpu"
                ) {
                    placeholder
                }

                RegattaRailSection(
                    title: String(localized: "regatta.rail.section.fleet", defaultValue: "Fleet"),
                    symbolName: "sailboat"
                ) {
                    placeholder
                }

                RegattaRailSection(
                    title: String(localized: "regatta.rail.section.memory", defaultValue: "Memory"),
                    symbolName: "books.vertical"
                ) {
                    placeholder
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("RegattaRailView")
    }

    /// Subtle empty-state placeholder shown under each section while content is
    /// not yet implemented. Keeps the section body non-zero in height so
    /// collapse/expand behaves correctly.
    private var placeholder: some View {
        Text(String(localized: "regatta.rail.section.placeholder", defaultValue: "Coming soon"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}
