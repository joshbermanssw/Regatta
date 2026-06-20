/// The classified result of running a single loop iteration's worker.
///
/// The loop engine never inspects worker internals; it only reacts to this
/// value type. A worker (the injectable abstraction wrapped by
/// ``RegattaLoopEngine``) returns one ``RegattaLoopOutcome`` per iteration.
public struct RegattaLoopOutcome: Equatable, Sendable {
    /// How an iteration concluded, from the engine's point of view.
    public enum Kind: String, Equatable, Sendable, Codable {
        /// The iteration completed and the goal is considered reached.
        ///
        /// For an `N iterations` loop this is treated like any other completed
        /// iteration; for future judged/test stop conditions (#20/#21) this is
        /// the signal a pluggable condition can use to stop.
        case succeeded

        /// The iteration completed but the goal is not yet reached; the loop
        /// should keep going (subject to stop conditions and caps).
        case progressed

        /// The iteration failed in a way that should stop the loop and mark it
        /// failed (the worker errored, exited non-zero, etc.).
        case failed
    }

    /// The classification of this iteration.
    public let kind: Kind

    /// A short, human-readable summary of what happened this iteration.
    ///
    /// Surfaced verbatim in the iteration history for the UI. Keep it to one
    /// line; the engine does not truncate it.
    public let summary: String

    /// The number of model tokens this iteration consumed, used to enforce the
    /// token-budget safety cap. Pass `0` when token accounting is unavailable.
    public let tokensUsed: Int

    /// Creates a worker outcome.
    ///
    /// - Parameters:
    ///   - kind: How the iteration concluded.
    ///   - summary: A one-line, human-readable summary for the history.
    ///   - tokensUsed: Tokens consumed this iteration (default `0`).
    public init(kind: Kind, summary: String, tokensUsed: Int = 0) {
        self.kind = kind
        self.summary = summary
        self.tokensUsed = tokensUsed
    }
}
