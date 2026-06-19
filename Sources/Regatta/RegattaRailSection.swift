import SwiftUI

/// A single collapsible section in the Regatta right-rail, with a labeled header
/// and an expandable content area. The header rows model the cmux sidebar
/// group-header chrome (chevron + title, toggling `isCollapsed` on tap).
struct RegattaRailSection<Content: View>: View {
    let title: String
    let symbolName: String?
    @ViewBuilder let content: () -> Content

    @State private var isCollapsed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if !isCollapsed {
                content()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var headerRow: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)

                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .rightSidebarChromeBar()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isCollapsed
                ? String.localizedStringWithFormat(
                    String(localized: "regatta.rail.section.expand.a11y", defaultValue: "Expand %@"),
                    title
                )
                : String.localizedStringWithFormat(
                    String(localized: "regatta.rail.section.collapse.a11y", defaultValue: "Collapse %@"),
                    title
                )
        )
        .rightSidebarChromeBottomBorder()
    }
}
