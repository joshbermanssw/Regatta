public import Foundation

/// The built-in ``RegattaLoopCondition`` for issue #19: handles
/// ``RegattaLoopStopCondition/manual`` and ``RegattaLoopStopCondition/iterations(_:)``,
/// plus the universal worker-driven stops (a ``RegattaLoopOutcome/Kind/failed``
/// iteration fails the loop; a ``RegattaLoopOutcome/Kind/succeeded`` iteration
/// stops with ``RegattaLoopStopReason/goalReached``).
///
/// Manual loops never stop themselves here — they rely on
/// ``RegattaLoopEngine/requestManualStop()`` or a safety cap. Richer conditions
/// (#20/#21) are separate conformers; this one is intentionally minimal.
public struct RegattaBuiltInLoopCondition: RegattaLoopCondition {
    /// Creates the built-in condition.
    public init() {}

    /// Applies the manual / `N iterations` rules plus worker-driven stops.
    ///
    /// - Parameter context: The post-iteration context.
    /// - Returns: The loop's next move.
    public func evaluate(_ context: RegattaLoopConditionContext) -> RegattaLoopDecision {
        // A failed iteration always fails the loop, regardless of stop condition.
        if context.lastIteration.outcome.kind == .failed {
            return .fail(summary: context.lastIteration.summary)
        }

        // A worker that reports the goal reached stops the loop normally.
        if context.lastIteration.outcome.kind == .succeeded {
            return .stop(.goalReached)
        }

        switch context.configuration.stopCondition {
        case .manual:
            // Manual loops only end via requestManualStop() or a safety cap.
            return .continue
        case .iterations(let count):
            if context.completedIterations >= count {
                return .stop(.iterationCountMet)
            }
            return .continue
        }
    }
}
