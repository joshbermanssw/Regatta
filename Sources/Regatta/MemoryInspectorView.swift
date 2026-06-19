import SwiftUI
import RegattaMemory

// MARK: - MemoryInspectorView

/// The Memory rail section: a live scope-tree inspector backed by
/// ``RegattaMemoryViewModel``.
///
/// ## Layout
/// - A scope tree rendered as indented disclosure rows. Each row shows the
///   scope segment name and a fact-count badge.
/// - Selecting a node expands it to reveal the direct facts for that scope,
///   each annotated with a type badge (heuristic / preference / fact / reference).
/// - An empty store shows a friendly "No memories yet" message.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// Rows inside `ForEach` receive **value snapshots** (`ScopeNode`, `MemoryFact`
/// are both `struct`). No `@Observable` view-model or store reference is
/// captured inside the `LazyVStack` / `ForEach` closures. The view-model is
/// read once at the `MemoryInspectorView` level and its result stored in local
/// `let` constants before entering the lazy boundary.
///
/// ## No state mutation in body
/// `expandedIDs` is mutated only inside button actions and the `.onAppear`
/// handler — never directly in a property computed as part of `body`.
struct MemoryInspectorView: View {
    let viewModel: RegattaMemoryViewModel

    /// The set of node IDs whose fact list is currently expanded.
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.loadError {
                errorView(message: error)
            } else if viewModel.nodes.isEmpty || viewModel.nodes.allSatisfy({ $0.totalCount == 0 }) {
                emptyView
            } else {
                treeView
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            viewModel.refresh()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
            Text(String(localized: "memory.inspector.loading", defaultValue: "Loading…"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "memory.inspector.empty.title", defaultValue: "No memories yet"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(localized: "memory.inspector.empty.body", defaultValue: "Facts learned by agents will appear here."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Tree

    /// The scope-tree list.
    ///
    /// Snapshot-boundary: `snapshots` is captured here (before the `ForEach`)
    /// as an immutable value array. Rows receive `ScopeNode` value copies only.
    private var treeView: some View {
        // Capture snapshots at this level — no @Observable read inside ForEach.
        let snapshots: [ScopeNode] = viewModel.nodes
        let expanded: Set<String> = expandedIDs

        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(snapshots) { node in
                // Skip nodes with zero total count (virtual root with no facts).
                if node.totalCount > 0 {
                    ScopeNodeRow(
                        node: node,
                        isExpanded: expanded.contains(node.id),
                        onToggle: { toggleExpanded(id: node.id) }
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func toggleExpanded(id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }
}

// MARK: - ScopeNodeRow

/// A single scope-tree row. Receives a `ScopeNode` **value snapshot** — no
/// `@Observable` / store reference is held (snapshot-boundary rule).
private struct ScopeNodeRow: View {
    let node: ScopeNode
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if isExpanded {
                factList
            }
        }
    }

    // MARK: Header row

    private var headerRow: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                // Indentation
                if node.depth > 0 {
                    Spacer()
                        .frame(width: CGFloat(node.depth) * 12)
                }

                // Chevron
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)

                // Scope segment label
                Text(node.segment)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Fact count badge
                Text("\(node.totalCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(.quaternary)
                    )
                    .accessibilityLabel(
                        String(
                            format: String(
                                localized: "memory.inspector.node.count.a11y",
                                defaultValue: "%lld facts"
                            ),
                            node.totalCount
                        )
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                format: String(
                    localized: "memory.inspector.node.a11y",
                    defaultValue: "%@ scope"
                ),
                node.segment
            )
        )
    }

    // MARK: Fact list

    /// The expanded list of facts for this node's direct scope.
    ///
    /// Snapshot-boundary: `facts` is captured before the inner `ForEach`.
    private var factList: some View {
        let facts: [MemoryFact] = node.directFacts
        let indentBase = CGFloat(node.depth) * 12 + 24

        return Group {
            if facts.isEmpty {
                Text(String(localized: "memory.inspector.node.no.direct.facts", defaultValue: "No facts at this scope"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, indentBase + 12)
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
            } else {
                ForEach(facts) { fact in
                    MemoryFactRow(fact: fact, indent: indentBase)
                }
            }
        }
    }
}

// MARK: - MemoryFactRow

/// A single fact row. Receives a `MemoryFact` **value snapshot** — no store
/// reference held (snapshot-boundary rule).
private struct MemoryFactRow: View {
    let fact: MemoryFact
    let indent: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer().frame(width: indent)
            typeBadge
            Text(fact.text)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private var typeBadge: some View {
        Text(badgeLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(badgeColor.opacity(0.15))
            )
            .fixedSize()
    }

    private var badgeLabel: String {
        switch fact.type {
        case .heuristic:
            return String(localized: "memory.inspector.badge.heuristic", defaultValue: "H")
        case .preference:
            return String(localized: "memory.inspector.badge.preference", defaultValue: "P")
        case .fact:
            return String(localized: "memory.inspector.badge.fact", defaultValue: "F")
        case .reference:
            return String(localized: "memory.inspector.badge.reference", defaultValue: "R")
        }
    }

    private var badgeColor: Color {
        switch fact.type {
        case .heuristic:  return .orange
        case .preference: return .blue
        case .fact:       return .green
        case .reference:  return .purple
        }
    }
}
