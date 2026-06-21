/// The exit-condition seam for a fix loop, mirroring the pluggable
/// `RegattaLoopCondition` from the Regatta loop engine (#19).
///
/// The loop engine asks the condition, once per iteration, whether to keep going
/// or stop. The condition is given the zero-based `iteration` index so it can
/// implement a cap, and it performs whatever observation it needs (for a CI fix
/// loop, re-polling the PR's checks) to decide.
///
/// ## Wiring note (#19)
/// This protocol is defined locally so the CI watch loop (#30) can ship before
/// the loop engine lands. #19 owns the real `RegattaLoopEngine` +
/// `RegattaLoopCondition`. When it merges, ``CIFixLoopCondition`` is re-pointed
/// at `RegattaLoopCondition` (the shapes match: a per-iteration async decision)
/// and the engine drives it instead of ``CIFixReactor``'s internal loop.
public protocol LoopConditionEvaluating: Sendable {
    /// Evaluates the loop's exit condition for one iteration.
    ///
    /// - Parameter iteration: The zero-based index of the iteration about to run
    ///   (or just completed, for a post-check condition).
    /// - Returns: ``LoopDecision/stop`` when the loop should end (the goal is met
    ///   or a cap is reached) or ``LoopDecision/continueLooping`` otherwise.
    func evaluate(iteration: Int) async -> LoopDecision
}
