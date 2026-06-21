public import Foundation

/// One entry in a loop's iteration history.
///
/// The engine appends a ``RegattaIterationRecord`` after every completed
/// iteration so the UI can render the full timeline: index, what happened, a
/// short summary, how long it took, and how many tokens it cost.
public struct RegattaIterationRecord: Equatable, Sendable {
    /// The zero-based index of this iteration within the loop.
    public let index: Int

    /// The worker outcome that this iteration produced.
    public let outcome: RegattaLoopOutcome

    /// A short, human-readable summary of the iteration (copied from
    /// ``RegattaLoopOutcome/summary``, surfaced directly for convenience).
    public let summary: String

    /// How long the iteration took, in seconds.
    public let duration: TimeInterval

    /// The tokens this iteration consumed (copied from
    /// ``RegattaLoopOutcome/tokensUsed``).
    public let tokensUsed: Int

    /// Creates an iteration record.
    ///
    /// - Parameters:
    ///   - index: The zero-based iteration index.
    ///   - outcome: The worker outcome for this iteration.
    ///   - duration: The iteration's wall-clock duration, in seconds.
    public init(index: Int, outcome: RegattaLoopOutcome, duration: TimeInterval) {
        self.index = index
        self.outcome = outcome
        self.summary = outcome.summary
        self.duration = duration
        self.tokensUsed = outcome.tokensUsed
    }
}
