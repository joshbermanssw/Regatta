import Foundation
import Observation
import RegattaMemory

// MARK: - ScopeNode

/// A value-type node in the scope tree built from ``MemoryFact`` data.
///
/// Each node represents one segment of a scope path (e.g. `"acme"` within
/// `"acme/webapp/billing"`) and carries the direct fact count for that exact
/// scope, the total count including all descendants, and snapshots of the
/// direct facts so list rows can be fed value copies (snapshot-boundary rule).
struct ScopeNode: Identifiable, Sendable {
    /// Unique identifier: the full scope path (e.g. `"acme/webapp"`).
    /// The root scope uses the empty string `""`.
    let id: String

    /// The single path segment shown as the row label (e.g. `"webapp"`).
    /// For the root scope this is `"/"`.
    let segment: String

    /// Facts whose `scopePath` exactly equals this node's scope path.
    /// These are value snapshots — no store reference.
    let directFacts: [MemoryFact]

    /// Number of facts at this scope level (direct only, not descendants).
    var directCount: Int { directFacts.count }

    /// Total fact count including all descendant scopes.
    let totalCount: Int

    /// Ordered child nodes (one per direct child scope segment).
    let children: [ScopeNode]

    /// Nesting depth used for indentation in the tree view.
    let depth: Int
}

// MARK: - RegattaMemoryViewModel

/// The view-model that owns a ``MemoryStore`` and derives a scope tree for the
/// Memory inspector rail section.
///
/// ## Lifecycle
/// Create once as `@State` in ``RegattaRailView`` and pass by reference into
/// ``MemoryInspectorView``. Call ``refresh()`` whenever the section becomes
/// visible; the store is currently append-only so a pull-on-appear is sufficient.
///
/// ## Concurrency
/// `@MainActor @Observable` — all published state is read directly by SwiftUI.
/// Async calls into the `MemoryStore` actor are made from `Task` closures and
/// assigned back on the main actor.
///
/// ## Snapshot-boundary rule
/// ``nodes`` is a flat array of ``ScopeNode`` value types. No store reference
/// escapes the `ForEach` / `List` boundary in the view layer.
@MainActor
@Observable
final class RegattaMemoryViewModel {

    // MARK: - Observable state

    /// Flat, depth-ordered array of scope-tree nodes derived from the store.
    /// The root node (if any facts exist at root scope) appears first.
    /// Children appear immediately after their parent, so rendering in order
    /// naturally produces an indented tree.
    private(set) var nodes: [ScopeNode] = []

    /// `true` while an async refresh is in flight.
    private(set) var isLoading = false

    /// Non-nil when a store operation throws; shown as an error banner.
    private(set) var loadError: String?

    // MARK: - Private non-observable

    /// The backing store. `@ObservationIgnored` — it is an internal resource
    /// handle, not a UI-observable property. `nil` if the backing directory
    /// could not be created; the view shows an error state in that case.
    @ObservationIgnored
    private let store: MemoryStore?

    /// The in-flight reload, cancelled and replaced on each `refresh()` so rapid
    /// re-entry (e.g. the rail section collapsed/expanded quickly) can't race two
    /// loads to a stale node set or a stuck spinner.
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a view-model backed by the given store.
    ///
    /// - Parameter store: The ``MemoryStore`` to inspect, or `nil` if the store
    ///   could not be initialised (e.g. the app-support directory is unavailable).
    ///   When `nil`, `refresh()` immediately sets a graceful error state.
    ///   Defaults to the app-lifetime store from ``RegattaMemoryManager``.
    init(store: MemoryStore? = nil) {
        // Default to the shared manager's store so that RegattaRailView can
        // create the VM with `RegattaMemoryViewModel()` just like BrainViewModel.
        // Callers that supply an explicit store (e.g. tests) override this.
        self.store = store ?? RegattaMemoryManager.shared.store
    }

    // MARK: - Public API

    /// Reloads all facts from the store and rebuilds the scope tree.
    ///
    /// Safe to call multiple times; concurrent calls are serialised through the
    /// actor. Assign results back on `@MainActor` so SwiftUI sees them inline.
    func refresh() {
        guard let store else {
            loadError = String(
                localized: "memory.inspector.error.unavailable",
                defaultValue: "Memory store unavailable"
            )
            return
        }
        refreshTask?.cancel()
        isLoading = true
        loadError = nil
        refreshTask = Task {
            let facts = await store.allFacts()
            guard !Task.isCancelled else { return }
            let built = Self.buildTree(from: facts)
            self.nodes = built
            self.isLoading = false
        }
    }

    // MARK: - Tree building (pure function)

    /// Builds a flat, depth-ordered sequence of ``ScopeNode`` values from a
    /// flat fact list. Pure and `Sendable`-safe (operates only on value types).
    ///
    /// The algorithm:
    /// 1. Group facts by their exact `scopePath`.
    /// 2. Collect the unique set of paths and sort them so parents always
    ///    precede children.
    /// 3. Recursively build the tree; for each node compute `totalCount` as
    ///    the sum of its own direct facts plus all descendant facts.
    /// 4. Flatten into a pre-order traversal (parent then children) so
    ///    `ForEach` renders them in order.
    private static func buildTree(from facts: [MemoryFact]) -> [ScopeNode] {
        guard !facts.isEmpty else { return [] }

        // Group facts by their exact scope path.
        var byScope: [String: [MemoryFact]] = [:]
        for fact in facts {
            byScope[fact.scopePath, default: []].append(fact)
        }

        // Collect all unique scope paths that appear in the data.
        // Sort lexicographically so parents always precede their children.
        let allPaths = byScope.keys.sorted()

        // Build children index: for each path, its direct child paths.
        // A child path has exactly one more "/" -separated segment.
        func directChildren(of parent: String, in paths: [String]) -> [String] {
            paths.filter { candidate in
                guard candidate != parent else { return false }
                if parent.isEmpty {
                    // Root's direct children have no "/" in their path.
                    return !candidate.contains("/")
                }
                guard candidate.hasPrefix(parent + "/") else { return false }
                let remainder = String(candidate.dropFirst(parent.count + 1))
                return !remainder.contains("/")
            }
        }

        // Recursively build a ScopeNode and its descendants.
        func buildNode(path: String, depth: Int) -> ScopeNode {
            let directFacts = byScope[path] ?? []
            let childPaths = directChildren(of: path, in: allPaths)
            let children = childPaths.map { buildNode(path: $0, depth: depth + 1) }

            let descendantCount = children.reduce(0) { $0 + $1.totalCount }
            let totalCount = directFacts.count + descendantCount

            let segment: String
            if path.isEmpty {
                segment = "/"
            } else {
                segment = path.split(separator: "/").last.map(String.init) ?? path
            }

            return ScopeNode(
                id: path,
                segment: segment,
                directFacts: directFacts,
                totalCount: totalCount,
                children: children,
                depth: depth
            )
        }

        // Build the root node. The root represents the empty-string scope ("").
        // If there are no root-scope facts but there are scoped facts, we still
        // build a virtual root to anchor the tree.
        let rootNode = buildNode(path: "", depth: 0)

        // Flatten using pre-order traversal (parent before children).
        func flatten(_ node: ScopeNode) -> [ScopeNode] {
            var result = [node]
            for child in node.children {
                result.append(contentsOf: flatten(child))
            }
            return result
        }

        return flatten(rootNode)
    }
}
