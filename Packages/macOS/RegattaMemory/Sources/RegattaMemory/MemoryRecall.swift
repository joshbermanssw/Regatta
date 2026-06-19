/// The result of a budgeted recall operation performed by ``MemoryAllocator``.
///
/// `MemoryRecall` is a value type — it is a snapshot of the allocation decision
/// and can be passed freely across concurrency domains.
///
/// ## Text fields
///
/// - ``injectionText``: A compact Markdown block ready to prepend to an agent
///   prompt. Facts are grouped by ``MemoryFactType`` and rendered as bullets.
/// - ``previewText``: A short human-readable summary intended for UI display
///   (e.g. the Allocator preview panel in the Memory inspector). It includes
///   the selection count, total count, and token usage, followed by the same
///   bullets as ``injectionText``.
///
/// ## Token accounting
///
/// ``usedTokens`` is always `<= budgetTokens`. If no facts fit within the
/// budget, both values are 0 and ``selected`` is empty.
public struct MemoryRecall: Sendable {
    // MARK: - Stored properties

    /// The facts selected for injection, ordered by relevance (nearer scope
    /// first, then most-recently-updated within each scope level).
    public let selected: [MemoryFact]

    /// The total number of resolved facts considered before the budget cut.
    /// Includes both selected and dropped facts.
    public let totalFacts: Int

    /// A Markdown block to prepend to an agent prompt.
    ///
    /// Format:
    /// ```
    /// ## Memory
    ///
    /// ### Heuristics
    /// - <text>
    ///
    /// ### Facts
    /// - <text>
    /// …
    /// ```
    ///
    /// Empty when ``selected`` is empty (returns the empty string `""`).
    public let injectionText: String

    /// A short human-readable summary for UI display.
    ///
    /// Example:
    /// ```
    /// 3 of 7 facts · ~120/200 tokens
    ///
    /// - <text>
    /// - <text>
    /// - <text>
    /// ```
    ///
    /// Empty when ``selected`` is empty.
    public let previewText: String

    /// The number of tokens consumed by ``injectionText`` as estimated by the
    /// ``TokenEstimating`` implementation used during the recall.
    public let usedTokens: Int

    /// The token budget passed to ``MemoryAllocator/recall(forScope:budgetTokens:)``.
    public let budgetTokens: Int

    // MARK: - Init

    /// Memberwise initialiser. All fields are set by ``MemoryAllocator``.
    public init(
        selected: [MemoryFact],
        totalFacts: Int,
        injectionText: String,
        previewText: String,
        usedTokens: Int,
        budgetTokens: Int
    ) {
        self.selected = selected
        self.totalFacts = totalFacts
        self.injectionText = injectionText
        self.previewText = previewText
        self.usedTokens = usedTokens
        self.budgetTokens = budgetTokens
    }
}
