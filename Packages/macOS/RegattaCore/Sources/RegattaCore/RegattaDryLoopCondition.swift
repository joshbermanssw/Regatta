/// The `dry` ``RegattaLoopCondition`` for issue #21: stop the loop once an
/// iteration produces no new changes.
///
/// The dry detection itself runs in ``RegattaDryWorker`` (which probes the
/// worktree and re-stamps a no-diff iteration as
/// ``RegattaLoopOutcome/Kind/succeeded``); this condition reads that signal. A
/// `succeeded` iteration stops the loop with
/// ``RegattaLoopStopReason/goalReached`` ("no more work to do"), a `failed`
/// iteration fails it, and otherwise the loop continues — letting the engine's
/// hard ``RegattaLoopSafetyCaps`` still backstop a worktree that never settles.
///
/// Pair it with ``RegattaDryWorker``:
/// ```swift
/// RegattaLoopEngine(
///     configuration: config,
///     worker: RegattaDryWorker(wrapping: inner, worktreePath: path, journal: journal),
///     condition: RegattaDryLoopCondition()
/// )
/// ```
public struct RegattaDryLoopCondition: RegattaLoopCondition {
    /// Creates the dry condition.
    public init() {}

    /// Stops on a `succeeded` (dry) iteration, fails on a `failed` one, else
    /// continues.
    ///
    /// - Parameter context: The post-iteration context.
    /// - Returns: The loop's next move.
    public func evaluate(_ context: RegattaLoopConditionContext) -> RegattaLoopDecision {
        switch context.lastIteration.outcome.kind {
        case .failed:
            return .fail(summary: context.lastIteration.summary)
        case .succeeded:
            // The dry worker stamps `succeeded` when an iteration left no new
            // changes — that is the dry stop.
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
