/// The `LLM-judged` ``RegattaLoopCondition`` for issue #21: stop the loop when
/// the brain judges the goal met.
///
/// The brain call itself runs in ``RegattaLLMJudgedWorker`` (which records the
/// verdict and re-stamps a "goal met" iteration as
/// ``RegattaLoopOutcome/Kind/succeeded``); this condition reads that signal. A
/// `succeeded` iteration stops the loop with
/// ``RegattaLoopStopReason/goalReached``, a `failed` iteration fails it (a judge
/// error surfaces as a failed iteration), and otherwise the loop continues —
/// with the engine's hard ``RegattaLoopSafetyCaps`` still backstopping a loop
/// the judge never declares complete.
///
/// Pair it with ``RegattaLLMJudgedWorker``:
/// ```swift
/// RegattaLoopEngine(
///     configuration: config,
///     worker: RegattaLLMJudgedWorker(wrapping: inner, judge: brainJudge, journal: journal),
///     condition: RegattaLLMJudgedLoopCondition()
/// )
/// ```
public struct RegattaLLMJudgedLoopCondition: RegattaLoopCondition {
    /// Creates the LLM-judged condition.
    public init() {}

    /// Stops on a `succeeded` (judge: goal met) iteration, fails on a `failed`
    /// one, else continues.
    ///
    /// - Parameter context: The post-iteration context.
    /// - Returns: The loop's next move.
    public func evaluate(_ context: RegattaLoopConditionContext) -> RegattaLoopDecision {
        switch context.lastIteration.outcome.kind {
        case .failed:
            return .fail(summary: context.lastIteration.summary)
        case .succeeded:
            return .stop(.goalReached)
        case .progressed:
            return .continue
        case .cancelled:
            // A cancelled/killed worker stops the loop — never a retry. The
            // engine normally intercepts this ahead of the condition; handled
            // here too so the contract holds regardless of call order.
            return .stop(.cancelled)
        }
    }
}
