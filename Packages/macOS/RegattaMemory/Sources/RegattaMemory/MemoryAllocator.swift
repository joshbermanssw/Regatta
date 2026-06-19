/// An actor that, given a scope and a token budget, selects the most relevant
/// resolved facts, formats them into a prompt-injection block, and produces a
/// human-readable preview.
///
/// ## Relevance ordering
///
/// ``recall(forScope:budgetTokens:)`` first calls
/// ``MemoryStore/resolvedFacts(forScope:)``, which already returns facts in
/// **ancestor-to-nearest** order with conflict-supersede applied (nearer scope
/// overrides ancestor for the same type + subject). The allocator then re-sorts
/// this list so the **most locally relevant** facts come first:
///
/// 1. **Nearer scope first** (target scope facts before ancestor facts).
///    Depth is measured as the number of "/" separators in `scopePath`; a
///    fact at `"acme/webapp/billing"` (depth 2) ranks above one at `"acme"`
///    (depth 0) when the target scope is `"acme/webapp/billing"`.
/// 2. **Most-recently-updated first** within the same scope depth
///    (`updatedAt` descending, then `createdAt` descending as a tiebreaker).
///
/// This ordering ensures that local, fresh knowledge fills the budget before
/// broad inherited heuristics do.
///
/// ## Budget accounting
///
/// Facts are selected greedily in relevance order. Before adding each fact the
/// allocator estimates the token cost of the **full injection block** if that
/// fact were included. A fact is selected if and only if the new total does NOT
/// exceed `budgetTokens`. Facts that would push the total over the budget are
/// skipped (they are not retried later — the greedy pass is a single forward
/// scan). This means a very long fact early in the list can block a shorter one
/// that would fit; the ordering rule above mitigates this by putting the highest-
/// value facts first.
///
/// Token cost is estimated by the injected ``TokenEstimating`` implementation.
/// The default is ``DefaultTokenEstimator`` (≈4 chars/token). Tests should
/// supply a deterministic stub.
///
/// ## Usage
///
/// ```swift
/// let store = try MemoryStore(baseDirectory: dir)
/// let allocator = MemoryAllocator(store: store)
/// let recall = await allocator.recall(forScope: "acme/webapp/billing", budgetTokens: 400)
/// // Prepend recall.injectionText to the agent prompt.
/// ```
public actor MemoryAllocator {

    // MARK: - Stored properties

    private let store: MemoryStore
    private let estimator: any TokenEstimating

    // MARK: - Init

    /// Creates an allocator backed by `store`.
    ///
    /// - Parameters:
    ///   - store: The memory store from which facts are recalled.
    ///   - estimator: Token estimator used for budget accounting. Defaults to
    ///     ``DefaultTokenEstimator`` (≈4 chars/token). Inject a custom
    ///     implementation in tests to make budgeting deterministic.
    public init(store: MemoryStore, estimator: any TokenEstimating = DefaultTokenEstimator()) {
        self.store = store
        self.estimator = estimator
    }

    // MARK: - Public API

    /// Selects the most relevant facts for `scope` within `budgetTokens` and
    /// returns a ``MemoryRecall`` containing the injection block, preview text,
    /// and accounting information.
    ///
    /// ## Relevance ordering (documented on ``MemoryAllocator``)
    ///
    /// Facts are ranked nearer-scope first, then most-recently-updated first.
    ///
    /// ## Budget rule (documented on ``MemoryAllocator``)
    ///
    /// Greedy forward scan: a fact is included iff the estimated token cost of
    /// the new injection block does not exceed `budgetTokens`.
    ///
    /// - Parameters:
    ///   - scope: The target scope path (e.g. `"acme/webapp/billing"`). Use
    ///     `""` for root.
    ///   - budgetTokens: Maximum token budget for the injection block. A budget
    ///     of 0 always yields an empty recall.
    /// - Returns: A ``MemoryRecall`` with `usedTokens <= budgetTokens`.
    public func recall(forScope scope: String, budgetTokens: Int) async -> MemoryRecall {
        guard budgetTokens > 0 else {
            return MemoryRecall(
                selected: [],
                totalFacts: 0,
                injectionText: "",
                previewText: "",
                usedTokens: 0,
                budgetTokens: budgetTokens
            )
        }

        // 1. Pull the inheritance-aware resolved set (nearer overrides ancestor
        //    for same type+subject; superseded facts excluded).
        let resolved = await store.resolvedFacts(forScope: scope)
        let totalFacts = resolved.count

        guard !resolved.isEmpty else {
            return MemoryRecall(
                selected: [],
                totalFacts: 0,
                injectionText: "",
                previewText: "",
                usedTokens: 0,
                budgetTokens: budgetTokens
            )
        }

        // 2. Re-sort by relevance: nearer scope first (higher scopePath depth
        //    for the target scope = more relevant), then most-recently-updated
        //    descending, then most-recently-created descending as a tiebreaker.
        //
        //    "Depth" here is the component count of the fact's own scopePath —
        //    not the target scope. A fact at "acme/webapp/billing" has 3
        //    components and ranks above one at "acme" (1 component) when both
        //    apply to the same target scope.
        let ranked = resolved.sorted { lhs, rhs in
            let lhsDepth = scopeDepth(lhs.scopePath)
            let rhsDepth = scopeDepth(rhs.scopePath)
            if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.createdAt > rhs.createdAt
        }

        // 3. Greedy forward scan: add each fact if the new injection block
        //    still fits within the budget.
        var selected: [MemoryFact] = []
        for candidate in ranked {
            let tentative = Self.buildInjectionText(for: selected + [candidate])
            let cost = estimator.estimate(tentative)
            if cost <= budgetTokens {
                selected.append(candidate)
            }
            // If it doesn't fit, skip it (no retry later in this pass).
        }

        // 4. Build the final injection + preview texts.
        let injectionText = Self.buildInjectionText(for: selected)
        let usedTokens = selected.isEmpty ? 0 : estimator.estimate(injectionText)
        let previewText = Self.buildPreviewText(
            selected: selected,
            totalFacts: totalFacts,
            usedTokens: usedTokens,
            budgetTokens: budgetTokens
        )

        return MemoryRecall(
            selected: selected,
            totalFacts: totalFacts,
            injectionText: injectionText,
            previewText: previewText,
            usedTokens: usedTokens,
            budgetTokens: budgetTokens
        )
    }

    // MARK: - Private helpers

    /// Returns the number of path components in `scopePath`.
    ///
    /// Root scope (`""`) → 0. `"acme"` → 1. `"acme/webapp"` → 2.
    private func scopeDepth(_ scopePath: String) -> Int {
        guard !scopePath.isEmpty else { return 0 }
        return scopePath.split(separator: "/", omittingEmptySubsequences: true).count
    }

    /// Builds the Markdown injection block for `facts`.
    ///
    /// Facts are grouped by ``MemoryFactType`` in a stable display order
    /// (heuristic → preference → fact → reference). Each group appears as a
    /// `###` heading with one bullet per fact. The outer heading is `## Memory`.
    ///
    /// Returns `""` when `facts` is empty.
    private static func buildInjectionText(for facts: [MemoryFact]) -> String {
        guard !facts.isEmpty else { return "" }

        var lines: [String] = ["## Memory", ""]

        // Group by type in a fixed display order.
        let typeOrder: [MemoryFactType] = [.heuristic, .preference, .fact, .reference]
        for factType in typeOrder {
            let group = facts.filter { $0.type == factType }
            guard !group.isEmpty else { continue }
            lines.append("### \(displayName(for: factType))")
            for fact in group {
                // Trim trailing whitespace/newlines from multi-line facts and
                // use only the first line as the bullet (keeps injection compact).
                let bullet = fact.text
                    .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    ?? fact.text.trimmingCharacters(in: .whitespaces)
                lines.append("- \(bullet)")
            }
            lines.append("")
        }

        // Drop the trailing blank line.
        if lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Builds a short human-readable preview for the UI inspector.
    ///
    /// Format: `"N of M facts · ~U/B tokens"` followed by the same bullets as
    /// the injection block.
    private static func buildPreviewText(
        selected: [MemoryFact],
        totalFacts: Int,
        usedTokens: Int,
        budgetTokens: Int
    ) -> String {
        guard !selected.isEmpty else { return "" }

        let header = "\(selected.count) of \(totalFacts) facts · ~\(usedTokens)/\(budgetTokens) tokens"
        let bullets = selected.map { fact -> String in
            let line = fact.text
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) }
                ?? fact.text.trimmingCharacters(in: .whitespaces)
            return "- \(line)"
        }
        return ([header, ""] + bullets).joined(separator: "\n")
    }

    /// Returns the display heading for a fact type.
    private static func displayName(for type: MemoryFactType) -> String {
        switch type {
        case .heuristic:  return "Heuristics"
        case .preference: return "Preferences"
        case .fact:       return "Facts"
        case .reference:  return "References"
        }
    }
}
