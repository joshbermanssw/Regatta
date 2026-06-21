/// The information a ``RegattaLoopCondition`` sees when deciding whether to
/// continue after an iteration.
///
/// Passed by the engine to the condition immediately after an iteration's record
/// is appended to the history. Everything a condition needs to make a normal
/// (non-cap) decision is here; the engine enforces the hard caps itself.
public struct RegattaLoopConditionContext: Equatable, Sendable {
    /// The loop configuration (goal, stop condition, caps).
    public let configuration: RegattaLoopConfiguration

    /// The record of the iteration that just completed.
    public let lastIteration: RegattaIterationRecord

    /// The full history including ``lastIteration``.
    public let history: [RegattaIterationRecord]

    /// The number of iterations completed so far (equal to `history.count`).
    public var completedIterations: Int { history.count }

    /// Creates a condition context.
    ///
    /// - Parameters:
    ///   - configuration: The loop configuration.
    ///   - lastIteration: The iteration that just completed.
    ///   - history: The full history including `lastIteration`.
    public init(
        configuration: RegattaLoopConfiguration,
        lastIteration: RegattaIterationRecord,
        history: [RegattaIterationRecord]
    ) {
        self.configuration = configuration
        self.lastIteration = lastIteration
        self.history = history
    }
}
