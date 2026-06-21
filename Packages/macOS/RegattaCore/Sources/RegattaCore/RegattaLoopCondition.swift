public import Foundation

/// The pluggable stop-condition seam for the loop engine.
///
/// The engine asks its condition, after each iteration, whether to
/// ``RegattaLoopDecision/continue``, ``RegattaLoopDecision/stop(_:)``, or
/// ``RegattaLoopDecision/fail(summary:)``. Issue #19 ships only
/// ``RegattaBuiltInLoopCondition`` (manual + `N iterations`); the deterministic
/// test condition (#20) and LLM-judged condition (#21) are future conformers,
/// composed without changing ``RegattaLoopEngine``.
///
/// A condition decides *normal* exits only. The engine layers the hard
/// ``RegattaLoopSafetyCaps`` on top, and a cap always wins over a condition's
/// ``RegattaLoopDecision/continue``.
public protocol RegattaLoopCondition: Sendable {
    /// Decides what the loop should do after an iteration completes.
    ///
    /// - Parameter context: The configuration, the iteration that just
    ///   completed, and the full history so far.
    /// - Returns: The loop's next move.
    func evaluate(_ context: RegattaLoopConditionContext) -> RegattaLoopDecision
}
