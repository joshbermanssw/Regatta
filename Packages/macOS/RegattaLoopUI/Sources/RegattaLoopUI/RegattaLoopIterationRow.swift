public import Foundation
public import RegattaCore

/// An immutable, `Identifiable` value snapshot of one iteration, shaped for the
/// loop view's history list.
///
/// The history list lives below a `LazyVStack` snapshot boundary, so its rows
/// must receive value snapshots and never the view model or engine. This type is
/// that snapshot: it carries everything a row renders (index, outcome kind,
/// summary, duration, tokens) and conforms to `Identifiable` for stable
/// `ForEach` diffing.
public struct RegattaLoopIterationRow: Identifiable, Equatable, Sendable {
    /// Stable identity: the iteration index (unique and monotonic within a run).
    public var id: Int { index }

    /// The zero-based iteration index.
    public let index: Int

    /// How this iteration concluded.
    public let kind: RegattaLoopOutcome.Kind

    /// A one-line, human-readable summary of the iteration.
    public let summary: String

    /// Wall-clock duration of the iteration, in seconds.
    public let duration: TimeInterval

    /// Tokens consumed by the iteration.
    public let tokensUsed: Int

    /// Creates an iteration row snapshot.
    ///
    /// - Parameters:
    ///   - index: The zero-based iteration index.
    ///   - kind: How the iteration concluded.
    ///   - summary: A one-line summary.
    ///   - duration: Wall-clock duration in seconds.
    ///   - tokensUsed: Tokens consumed.
    public init(
        index: Int,
        kind: RegattaLoopOutcome.Kind,
        summary: String,
        duration: TimeInterval,
        tokensUsed: Int
    ) {
        self.index = index
        self.kind = kind
        self.summary = summary
        self.duration = duration
        self.tokensUsed = tokensUsed
    }

    /// Projects an engine ``RegattaIterationRecord`` into a row snapshot.
    ///
    /// - Parameter record: The recorded iteration from the engine history.
    public init(record: RegattaIterationRecord) {
        self.index = record.index
        self.kind = record.outcome.kind
        self.summary = record.summary
        self.duration = record.duration
        self.tokensUsed = record.tokensUsed
    }
}
