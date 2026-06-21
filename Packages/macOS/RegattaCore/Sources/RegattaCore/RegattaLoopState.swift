/// An immutable snapshot of a loop's state, queryable for the UI.
///
/// The engine produces a fresh ``RegattaLoopState`` after every transition. It
/// is a value type so it can be handed to a `@MainActor @Observable` view model
/// and rendered without reaching back into the engine actor. The full iteration
/// history survives within the session here.
public struct RegattaLoopState: Equatable, Sendable {
    /// The configuration the loop was started with.
    public let configuration: RegattaLoopConfiguration

    /// The current lifecycle status.
    public let status: RegattaLoopStatus

    /// The recorded iteration history, in iteration order.
    public let history: [RegattaIterationRecord]

    /// The number of iterations completed so far (equal to `history.count`).
    public var completedIterations: Int { history.count }

    /// The total tokens consumed across all completed iterations.
    public let totalTokensUsed: Int

    /// Creates a loop-state snapshot.
    ///
    /// - Parameters:
    ///   - configuration: The loop configuration.
    ///   - status: The current lifecycle status.
    ///   - history: The recorded iteration history.
    public init(
        configuration: RegattaLoopConfiguration,
        status: RegattaLoopStatus,
        history: [RegattaIterationRecord]
    ) {
        self.configuration = configuration
        self.status = status
        self.history = history
        self.totalTokensUsed = history.reduce(0) { $0 + $1.tokensUsed }
    }
}
